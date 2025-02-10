FROM python:3.11

WORKDIR /app/backend

COPY ./app/backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY ./app/backend /app/backend
COPY ./app/backend/core /app/backend/core # Make sure core is copied.

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
