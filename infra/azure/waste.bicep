// NudgeBee Scenario Lab - waste tier, Azure.
//
// The Azure twin of infra/cloudformation/waste.yaml: deliberately wasteful and
// misconfigured (but harmless) resources so NudgeBee's cost, rightsizing and
// security findings can be shown without injecting any fault. There is
// nothing to run - the finding IS the resource.
//
// SAFETY: every resource here is inert. Nothing accepts traffic, nothing runs
// workloads, and the open NSG is attached to NOTHING. It lives in a resource
// group of its own with its own small network, so it needs nothing from the
// lab tier and deleting that group removes all of it.
//
//   CLOUD=azure ./scripts/deploy.sh waste
//
// One AWS finding has no Azure twin: "unencrypted volume". Azure encrypts
// every managed disk at rest and that cannot be switched off, so there is no
// honest way to create the finding.

targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Prefix for every resource. Matches SCENARIO_LAB_STACK plus -waste.')
param labName string = resourceGroup().name

@description('Admin public key for the two VMs. Required by Azure, never used.')
param sshPublicKey string

param adminUsername string = 'labadmin'

// B4ms rather than a D-series default: many trial and sponsored subscriptions
// cannot create Dsv5 at all, and an idle 16 GiB burstable VM is just as clear
// a rightsizing finding.
@description('Deliberately too big for its (nonexistent) workload. Standard_B4ms ~ $120/mo.')
@allowed([
  'Standard_B4ms'
  'Standard_B8ms'
  'Standard_D4s_v3'
  'Standard_D4s_v5'
])
param oversizedVmSize string = 'Standard_B4ms'

@minValue(1)
@maxValue(100)
param wastedDiskSizeGb int = 20

@description('A managed disk attached to nothing, billing forever.')
param createUnattachedDisk bool = true

@description('A large VM sitting near-idle - the classic rightsizing finding. COSTS REAL MONEY.')
param createOversizedVm bool = true

@description('A VM you deallocate after deploy; its OS disk keeps billing.')
param createStoppedVm bool = true

@description('SSH and RDP open to the internet. Attached to nothing - a finding, not a hole.')
param createOpenNsg bool = true

@description('A static public IP associated with nothing (~$3.65/mo).')
param createUnattachedPublicIp bool = true

@description('A Standard load balancer with no backends and no traffic. Off by default.')
param createIdleLoadBalancer bool = false

var needsNetwork = createOversizedVm || createStoppedVm || createIdleLoadBalancer

// by ID rather than vnet.properties: the network is conditional, and Bicep
// cannot prove it exists whenever a VM or the load balancer does
var idleSubnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', '${labName}-vnet', 'idle')

func finding(tag string) object => {
  'nudgebee-scenario-lab': 'true'
  'nudgebee-finding': tag
}

var labTags = {
  'nudgebee-scenario-lab': 'true'
}

// ------------------------------------------------------------------ storage

resource unattachedDisk 'Microsoft.Compute/disks@2023-10-02' = if (createUnattachedDisk) {
  name: '${labName}-unattached-disk'
  location: location
  tags: finding('unattached-managed-disk')
  sku: {
    name: 'StandardSSD_LRS'
  }
  properties: {
    creationData: {
      createOption: 'Empty'
    }
    diskSizeGB: wastedDiskSizeGb
  }
}

resource unattachedPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = if (createUnattachedPublicIp) {
  name: '${labName}-unattached-pip'
  location: location
  tags: finding('unattached-public-ip')
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// ------------------------------------------------------------------ security

resource openNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (createOpenNsg) {
  name: '${labName}-open-to-world'
  location: location
  tags: finding('over-permissive-nsg')
  properties: {
    securityRules: [
      {
        name: 'ssh-from-anywhere'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'rdp-from-anywhere'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
    ]
  }
}

// ------------------------------------------------------------------ compute
// The two VMs sit in a network of their own with no public IPs and the
// default NSG rules, so nothing reaches them. They do no work at all, which is
// exactly what makes them findings.

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (needsNetwork) {
  name: '${labName}-vnet'
  location: location
  tags: labTags
  properties: {
    addressSpace: {
      addressPrefixes: ['10.43.0.0/24']
    }
    subnets: [
      {
        name: 'idle'
        properties: {
          addressPrefix: '10.43.0.0/24'
        }
      }
    ]
  }
}

var vms = [
  {
    create: createOversizedVm
    name: '${labName}-oversized'
    size: oversizedVmSize
    tag: 'oversized-vm'
  }
  {
    create: createStoppedVm
    name: '${labName}-stopped'
    size: 'Standard_B1s'
    tag: 'deallocated-vm-with-storage'
  }
]

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = [for v in vms: if (v.create) {
  name: '${v.name}-nic'
  location: location
  tags: labTags
  dependsOn: [
    vnet
  ]
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          subnet: {
            id: idleSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}]

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = [for (v, i) in vms: if (v.create) {
  name: v.name
  location: location
  tags: finding(v.tag)
  properties: {
    hardwareProfile: {
      vmSize: v.size
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        name: '${v.name}-os'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        diskSizeGB: 30
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    osProfile: {
      computerName: v.name
      adminUsername: adminUsername
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

// ------------------------------------------------------------------ idle spend

resource idleLb 'Microsoft.Network/loadBalancers@2023-11-01' = if (createIdleLoadBalancer) {
  name: '${labName}-idle-lb'
  location: location
  tags: finding('idle-load-balancer')
  dependsOn: [
    vnet
  ]
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'frontend'
        properties: {
          subnet: {
            id: idleSubnetId
          }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'empty'
      }
    ]
  }
}

// ------------------------------------------------------------------ outputs

output manualStepRequired string = createStoppedVm
  ? 'ARM cannot create a deallocated VM. Run: az vm deallocate --resource-group ${resourceGroup().name} --name ${labName}-stopped'
  : 'none'
