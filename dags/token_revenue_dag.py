"""Airflow DAG: run the token revenue integrity checks daily after the billing jobs land.

In production this would wait on upstream billing and metering loads; here it runs the same
steps as the GitHub Actions workflow.
"""
from datetime import datetime, timedelta

from airflow import DAG

try:  # Airflow 3
    from airflow.providers.standard.operators.bash import BashOperator
except ImportError:  # Airflow 2
    from airflow.operators.bash import BashOperator

PROJECT_DIR = "/opt/airflow/token-revenue-integrity"

default_args = {"retries": 2, "retry_delay": timedelta(minutes=10)}

with DAG(
    dag_id="token_revenue_integrity",
    description="Rate token usage, reconcile invoices, partner settlements, and credits, and publish exceptions",
    start_date=datetime(2026, 10, 1),
    schedule="0 12 * * *",
    catchup=False,
    default_args=default_args,
    tags=["billing", "finance"],
) as dag:
    load_and_build = BashOperator(
        task_id="dbt_build",
        bash_command=f"cd {PROJECT_DIR} && dbt build --profiles-dir .",
    )
    report = BashOperator(
        task_id="revenue_integrity_report",
        bash_command=f"cd {PROJECT_DIR} && python scripts/build_report.py",
    )
    ai_summary = BashOperator(
        task_id="claude_summary_for_finance",
        bash_command=f"cd {PROJECT_DIR} && python scripts/explain_exceptions.py",
    )

    load_and_build >> report >> ai_summary
