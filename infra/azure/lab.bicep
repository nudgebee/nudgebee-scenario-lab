// NudgeBee Scenario Lab - lab tier, Azure.
//
// The Azure twin of infra/cloudformation/lab.yaml: Linux VMs that scenarios
// are injected into through managed Run Command, plus Azure Monitor metric
// alerts so the damage shows up as an alert NudgeBee can pick up.
//
// NOT for production: scenarios deliberately degrade these VMs.
//
// Deploy into a resource group of its own - teardown is deleting that group:
//
//   CLOUD=azure ./scripts/deploy.sh

targetScope = 'resourceGroup'

@description('Azure region. Defaults to the resource group\'s.')
param location string = resourceGroup().location

@description('Prefix for every resource and alert. Matches SCENARIO_LAB_STACK in the control app.')
param labName string = resourceGroup().name

@description('Admin public key. Required by Azure, never used: nothing inbound is open and scenarios arrive through Run Command. deploy.sh generates a throwaway one.')
param sshPublicKey string

@description('Admin user the public key is installed for.')
param adminUsername string = 'labadmin'

// B1s is the closest match to the AWS lab's t3.micro (1 GiB, ~$7.50/mo) and,
// unlike the newer Bsv2 sizes, is offered to almost every subscription type -
// many trial and sponsored subscriptions cannot create Bsv2 or Dsv5 at all.
@description('Small is fine - scenarios saturate whatever they are given.')
@allowed([
  'Standard_B1s'
  'Standard_B1ms'
  'Standard_B2s'
  'Standard_B2ats_v2'
])
param vmSize string = 'Standard_B1s'

@minValue(1)
@maxValue(4)
param hostCount int = 2

@description('CIDR for the virtual network the lab creates.')
param labCidr string = '10.42.0.0/16'

@description('Percentage CPU that trips the CPU alert.')
param cpuThreshold int = 70

@description('Memory used percent that trips the memory alert (alerts on available memory below 100 minus this).')
param memoryThreshold int = 80

@description('Disk used percent that trips the disk alert (needs the Azure Monitor Agent).')
param diskThreshold int = 80

@description('Optional action group resource ID to notify when an alert fires - for example the one your NudgeBee Azure integration created. Empty means the alerts fire in Azure Monitor only.')
param actionGroupId string = ''

@description('Publish the failed-unit and process counts from each VM as custom metrics, and alert on them (service-down, proc-high). Needs the deployer to be allowed to assign roles (Owner or User Access Administrator): each VM is given Monitoring Metrics Publisher on itself. deploy.sh turns this off when the caller cannot, rather than failing the deployment.')
param publishHostMetrics bool = true

var tags = {
  'nudgebee-scenario-lab': 'true'
}
var hostNames = [for i in range(1, hostCount): '${labName}-host-${i}']

// Ubuntu rather than a RHEL-family image: it ships cron, iptables and systemd
// out of the box, which the catalogue's scenarios assume. stress-ng still has
// to be installed. Nothing here is Ubuntu-specific beyond the package manager.
var cloudInit = '''#cloud-config
package_update: true
packages:
  - stress-ng
  - cron
  - curl
write_files:
  # The two numbers no Azure metric carries. A failed systemd unit does not
  # move VM availability, and hundreds of sleeping processes move neither CPU
  # nor load - so service_failure and zombie_processes publish their own, the
  # same counts the AWS lab sends to CloudWatch. Posted to Azure Monitor custom
  # metrics with the VM's managed identity; needs Monitoring Metrics Publisher
  # on the VM, which lab.bicep grants when publishHostMetrics is on. Without
  # it the posts are refused and nothing else is affected.
  - path: /usr/local/bin/nb-host-metrics.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      IMDS=http://169.254.169.254/metadata
      TOKEN=$(curl -s -m 5 -H Metadata:true "$IMDS/identity/oauth2/token?api-version=2018-02-01&resource=https://monitoring.azure.com/" \
        | python3 -c 'import sys, json; print(json.load(sys.stdin).get("access_token", ""))' 2>/dev/null)
      [ -n "$TOKEN" ] || exit 0
      RID=$(curl -s -m 5 -H Metadata:true "$IMDS/instance/compute/resourceId?api-version=2021-02-01&format=text")
      LOC=$(curl -s -m 5 -H Metadata:true "$IMDS/instance/compute/location?api-version=2021-02-01&format=text")
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      FAILED=$(systemctl list-units --state=failed --no-legend --plain | grep -c . || true)
      PROCS=$(ps -e --no-headers | wc -l)
      for pair in "FailedSystemdUnits:$FAILED" "ProcessCount:$PROCS"; do
        name=${pair%%:*}; value=${pair##*:}
        curl -s -m 10 -o /dev/null -X POST "https://$LOC.monitoring.azure.com$RID/metrics" \
          -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
          -d "{\"time\":\"$NOW\",\"data\":{\"baseData\":{\"metric\":\"$name\",\"namespace\":\"NudgebeeScenarioLab\",\"series\":[{\"min\":$value,\"max\":$value,\"sum\":$value,\"count\":1}]}}}"
      done
  - path: /etc/systemd/system/nb-host-metrics.service
    content: |
      [Unit]
      Description=NudgeBee scenario lab - publish failed unit and process counts
      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/nb-host-metrics.sh
  - path: /etc/systemd/system/nb-host-metrics.timer
    content: |
      [Unit]
      Description=Publish failed unit and process counts every minute
      [Timer]
      OnBootSec=90
      # OnUnitInactiveSec: a oneshot that exits in a second never re-fires on OnUnitActiveSec
      OnUnitInactiveSec=60
      [Install]
      WantedBy=timers.target
runcmd:
  - systemctl enable --now cron
  - mkdir -p /opt/nudgebee-scenario
  - systemctl daemon-reload
  - systemctl enable --now nb-host-metrics.timer
'''

// ------------------------------------------------------------------ network
// A virtual network of its own, so the lab cannot land in one you care about.
// The NSG keeps Azure's default inbound rules - traffic from inside the
// virtual network is allowed, everything from the internet is denied - and
// adds nothing. Host-to-host traffic works; nothing else gets in.

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${labName}-hosts'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${labName}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [labCidr]
    }
    subnets: [
      {
        name: 'hosts'
        properties: {
          addressPrefix: cidrSubnet(labCidr, 24, 0)
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

// Outbound only. New Azure subnets get no default outbound internet, and the
// VMs need it: apt, the Azure Monitor Agent, and the network spike scenario.
// A public IP per VM is the cheapest way (a NAT gateway costs ~$32/mo); the
// NSG above still denies every inbound connection from the internet.
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = [for name in hostNames: {
  name: '${name}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}]

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = [for (name, i) in hostNames: {
  name: '${name}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: pip[i].id
          }
        }
      }
    ]
  }
}]

// ------------------------------------------------------------------ hosts

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [for (name, i) in hostNames: {
  name: name
  location: location
  tags: union(tags, {
    'scenario-role': i == 0 ? 'primary' : (i == 1 ? 'secondary' : 'spare')
  })
  // the Azure Monitor Agent authenticates with this
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${name}-os'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: name
      adminUsername: adminUsername
      customData: base64(cloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i].id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
  }
}]

// ------------------------------------------------------------------ guest metrics
// CPU, memory, network and availability are host metrics Azure publishes for
// every VM with no agent. Disk used percent is not - only the guest knows how
// full its filesystem is - so the Azure Monitor Agent sends that one into
// Azure Monitor Metrics, where a metric alert can watch it.

resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = [for (name, i) in hostNames: {
  parent: vm[i]
  name: 'AzureMonitorLinuxAgent'
  location: location
  tags: tags
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}]

resource dcr 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${labName}-guest-metrics'
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      performanceCounters: [
        {
          name: 'labCounters'
          streams: ['Microsoft-InsightsMetrics']
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            'Logical Disk(*)\\% Used Space'
            'Memory(*)\\% Used Memory'
          ]
        }
      ]
    }
    destinations: {
      azureMonitorMetrics: {
        name: 'azureMonitorMetrics-default'
      }
    }
    dataFlows: [
      {
        streams: ['Microsoft-InsightsMetrics']
        destinations: ['azureMonitorMetrics-default']
      }
    ]
  }
}

// Lets each VM post its own custom metrics (nb-host-metrics.sh), scoped to
// that VM alone. Assigning a role is what needs Owner-level rights to deploy.
var monitoringMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

resource metricsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (name, i) in hostNames: if (publishHostMetrics) {
  name: guid(vm[i].id, monitoringMetricsPublisher)
  scope: vm[i]
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringMetricsPublisher)
    principalId: vm[i].identity.principalId
    principalType: 'ServicePrincipal'
  }
}]

resource dcrLink 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = [for (name, i) in hostNames: {
  name: '${name}-guest-metrics'
  scope: vm[i]
  properties: {
    dataCollectionRuleId: dcr.id
  }
  dependsOn: [
    ama[i]
  ]
}]

// ------------------------------------------------------------------ alerts
// Named <lab>-host-N-<signal>, exactly like the CloudWatch alarms, so the
// catalogue's `signal` suffixes match on both clouds and NudgeBee events carry
// the same readable key.
//
// Every alert evaluates each minute over a five-minute window: Azure has no
// two-minute window, and one minute is too twitchy for a CPU average.

var actions = empty(actionGroupId) ? [] : [
  {
    actionGroupId: actionGroupId
  }
]

// Host 1 gets every signal. The others get CPU only - the same split as the
// AWS lab, since the scenarios that need memory, disk or network run on the
// primary host by default.
var hostAlerts = [
  {
    signal: 'cpu-high'
    description: 'CPU utilization high on scenario host'
    namespace: 'Microsoft.Compute/virtualMachines'
    metric: 'Percentage CPU'
    operator: 'GreaterThan'
    threshold: cpuThreshold
    aggregation: 'Average'
    custom: false
    allHosts: true
  }
  {
    signal: 'mem-high'
    description: 'Memory utilization high on scenario host (available memory low)'
    namespace: 'Microsoft.Compute/virtualMachines'
    metric: 'Available Memory Percentage'
    operator: 'LessThan'
    threshold: 100 - memoryThreshold
    aggregation: 'Average'
    custom: false
    allHosts: false
  }
  {
    signal: 'disk-high'
    description: 'Disk utilization high on scenario host (requires Azure Monitor Agent)'
    namespace: 'azure.vm.linux.guestmetrics'
    metric: 'disk/used_percent'
    operator: 'GreaterThan'
    threshold: diskThreshold
    aggregation: 'Maximum'
    custom: true
    allHosts: false
  }
  {
    signal: 'status-check'
    description: 'VM availability dropped on scenario host'
    namespace: 'Microsoft.Compute/virtualMachines'
    metric: 'VmAvailabilityMetric'
    operator: 'LessThan'
    threshold: 1
    aggregation: 'Minimum'
    custom: false
    allHosts: false
  }
  {
    // CloudWatch's NetworkOut alarm averages 50 MB per minute. Azure reports
    // a per-minute total, so the same rate over five minutes is 250 MB.
    signal: 'net-out-high'
    description: 'Outbound network unusually high on scenario host'
    namespace: 'Microsoft.Compute/virtualMachines'
    metric: 'Network Out Total'
    operator: 'GreaterThan'
    threshold: 250000000
    aggregation: 'Total'
    custom: false
    allHosts: false
  }
  {
    // Not on AWS. Azure's Percentage CPU does not count I/O wait, so the disk
    // I/O scenario left the CPU alert at ~3% while the disk ran at ~46% of its
    // bandwidth. Idle is 0-1%; 25% is clear of both.
    signal: 'disk-io-high'
    description: 'OS disk bandwidth unusually high on scenario host'
    namespace: 'Microsoft.Compute/virtualMachines'
    metric: 'OS Disk Bandwidth Consumed Percentage'
    operator: 'GreaterThan'
    threshold: 25
    aggregation: 'Average'
    custom: false
    allHosts: true
  }
  {
    // Published by nb-host-metrics.sh, not by Azure - see cloudInit.
    signal: 'service-down'
    description: 'A systemd unit is in failed state on scenario host'
    namespace: 'NudgebeeScenarioLab'
    metric: 'FailedSystemdUnits'
    operator: 'GreaterThan'
    threshold: 0
    aggregation: 'Maximum'
    custom: true
    allHosts: false
    hostMetric: true
  }
  {
    // ~120 processes at idle; zombie_processes adds ~400.
    signal: 'proc-high'
    description: 'Unusually many processes on scenario host'
    namespace: 'NudgebeeScenarioLab'
    metric: 'ProcessCount'
    operator: 'GreaterThan'
    threshold: 300
    aggregation: 'Maximum'
    custom: true
    allHosts: false
    hostMetric: true
  }
]

var alertPairs = flatten(map(range(0, hostCount), h => map(
  filter(hostAlerts, a => (h == 0 || a.allHosts) && (publishHostMetrics || !contains(a, 'hostMetric'))),
  a => union(a, { host: h })
)))

resource alert 'Microsoft.Insights/metricAlerts@2018-03-01' = [for a in alertPairs: {
  name: '${labName}-host-${a.host + 1}-${a.signal}'
  location: 'global'
  tags: tags
  properties: {
    description: '${a.description} ${a.host + 1}'
    severity: 2
    enabled: true
    scopes: [
      vm[a.host].id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: a.signal
          metricNamespace: a.namespace
          metricName: a.metric
          operator: a.operator
          threshold: a.threshold
          timeAggregation: a.aggregation
          // the guest metric does not exist until the agent has published it
          // once, and validation would refuse the rule at deploy time
          skipMetricValidation: a.custom
          // The guest metric has one series per mount, and Ubuntu's snap
          // packages are read-only images that always report 100% used. Without
          // this filter the disk alert is red from the moment it exists.
          dimensions: a.custom ? [
            {
              name: 'path'
              operator: 'Include'
              values: ['/']
            }
          ] : []
        }
      ]
    }
    actions: actions
  }
  dependsOn: [
    dcrLink
  ]
}]

// ------------------------------------------------------------------ outputs

output labNameOut string = labName
output hostNamesOut array = hostNames
output alertPrefix string = '${labName}-host-'
output vnetId string = vnet.id
output nextSteps string = 'Run: CLOUD=azure SCENARIO_LAB_STACK=${labName} ./scripts/run-local.sh  (then open http://127.0.0.1:8080)'
