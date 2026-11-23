FROM python:3.11-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --create-home campus
COPY fetch_study_model.py .
RUN python fetch_study_model.py
COPY . .
USER campus
CMD ["sh","-c","python -m alembic upgrade head && exec python -m uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000}"]
