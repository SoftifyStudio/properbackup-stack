FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir fastapi uvicorn python-multipart

COPY main.py .

ENV STORAGE_DIR=/data/objects
ENV MAX_CHUNK_BYTES=943718400
ENV STORAGE_AUTH_TOKEN=dev-storage-token

VOLUME ["/data/objects"]

EXPOSE 9000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "9000"]
