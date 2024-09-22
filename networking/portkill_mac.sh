#!/bin/bash

# Check if a process is running on port 8081
PID=$(lsof -ti:8501)

if [ -n "$PID" ]; then
  echo "Process running on port 8081 with PID: $PID"
  echo "Killing process..."
  kill -9 $PID
  echo "Process killed."
else
  echo "No process running on port 8081."
fi
