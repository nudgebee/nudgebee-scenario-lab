FROM python:3.12-slim

WORKDIR /app
COPY control/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY control/server /app/server
COPY control/web /app/web
COPY scenarios /app/scenarios

EXPOSE 8080
CMD ["uvicorn", "server.app:app", "--host", "0.0.0.0", "--port", "8080"]
