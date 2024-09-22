#!/bin/bash

# Find and kill the process running on port 8051
sudo fuser -k 8501/tcp

# Verify if the port is free
if sudo fuser 8501/tcp; then
    echo "Failed to kill the process on port 8051."
else
    echo "Successfully killed the process on port 8051."
fi
