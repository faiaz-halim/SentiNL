#!/bin/bash

# Extract the actual local Wi-Fi/Ethernet IP address (bypassing docker/podman virtual IPs)
HOST_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -n 1)

if [ -z "$HOST_IP" ]; then
    echo "⚠️ Could not detect local IP address. Defaulting to 127.0.0.1"
    HOST_IP="127.0.0.1"
fi

echo "=================================================="
echo "🌐 Detected Host IP: $HOST_IP"
echo "🚀 Launching SentiNL in Release Mode..."
echo "=================================================="

flutter run -d R5GYB1F743W --release \
  --dart-define=BACKEND_URL="http://$HOST_IP:8000" \
  --dart-define=MODEL_URL="http://$HOST_IP:8080/gemma-4-E2b-scam-q4_k_m.gguf"
