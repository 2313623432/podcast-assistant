#!/bin/sh
set -e
exec streamlit run app.py \
  --server.address=0.0.0.0 \
  --server.port="${PORT:-8501}" \
  --browser.gatherUsageStats=false
