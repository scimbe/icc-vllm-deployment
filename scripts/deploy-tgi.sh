#!/bin/bash

# Skript zum Deployment von Text Generation Inference (TGI) 
# TGI bietet eine OpenAI-kompatible API für die Ausführung von LLMs
set -e

# Pfad zum Skriptverzeichnis
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Lade Konfiguration
if [ -f "$ROOT_DIR/configs/config.sh" ]; then
    source "$ROOT_DIR/configs/config.sh"
else
    echo "Fehler: config.sh nicht gefunden."
    exit 1
fi

# Standard-Testmodell - frei verfügbares Modell für Fallback
FREE_MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"

# Verwende das konfigurierte Modell
MODEL_TO_USE="${MODEL_NAME:-$FREE_MODEL}"

# Entferne bestehende Deployments, falls vorhanden
if kubectl -n "$NAMESPACE" get deployment "$TGI_DEPLOYMENT_NAME" &> /dev/null; then
    echo "Entferne bestehendes Deployment..."
    kubectl -n "$NAMESPACE" delete deployment "$TGI_DEPLOYMENT_NAME" --ignore-not-found=true
fi

if kubectl -n "$NAMESPACE" get service "$TGI_SERVICE_NAME" &> /dev/null; then
    echo "Entferne bestehenden Service..."
    kubectl -n "$NAMESPACE" delete service "$TGI_SERVICE_NAME" --ignore-not-found=true
fi

# CUDA_DEVICES vorbereiten
CUDA_DEVICES="0"
if [ "$USE_GPU" == "true" ] && [ "$GPU_COUNT" -gt 1 ]; then
    for ((i=1; i<GPU_COUNT; i++)); do
        CUDA_DEVICES="${CUDA_DEVICES},$i"
    done
fi

# Erstelle temporäre Datei
TMP_FILE=$(mktemp)

# Logge den HuggingFace-Token-Status (redacted für Sicherheit)
if [ -n "$HUGGINGFACE_TOKEN" ]; then
    echo "HuggingFace-Token ist konfiguriert (${HUGGINGFACE_TOKEN:0:3}...${HUGGINGFACE_TOKEN: -3})"
else
    echo "WARNUNG: Kein HuggingFace-Token konfiguriert. Gated Modelle werden nicht funktionieren."
fi

# Schreibe YAML für TGI Deployment
cat > "$TMP_FILE" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${TGI_DEPLOYMENT_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: llm-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llm-server
  template:
    metadata:
      labels:
        app: llm-server
    spec:
EOF

# GPU Tolerationen hinzufügen wenn GPU aktiviert
if [ "$USE_GPU" == "true" ]; then
    cat >> "$TMP_FILE" << EOF
      tolerations:
      - key: "${GPU_TYPE}"
        operator: "Exists"
        effect: "NoSchedule"
EOF
fi

# Container-Definition
cat >> "$TMP_FILE" << EOF
      containers:
      - name: tgi
        image: ghcr.io/huggingface/text-generation-inference:latest
        imagePullPolicy: IfNotPresent
        command: ["text-generation-launcher"]
        args:
        - "--model-id=${MODEL_TO_USE}"
        - "--port=8000"
EOF

# Mixed Precision basierend auf GPU-Typ
if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
    cat >> "$TMP_FILE" << EOF
        - "--dtype=bfloat16"
EOF
else
    cat >> "$TMP_FILE" << EOF
        - "--dtype=float16"
EOF
fi

# Speicher-Management für A100
if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
    cat >> "$TMP_FILE" << EOF
        - "--max-concurrent-requests=16"
        - "--max-input-length=${MAX_INPUT_LENGTH:-4096}"
        - "--max-total-tokens=${MAX_TOTAL_TOKENS:-8192}"
EOF
fi

# Quantisierungsoptionen
if [ -n "$QUANTIZATION" ]; then
    if [ "$QUANTIZATION" == "awq" ]; then
        cat >> "$TMP_FILE" << EOF
        - "--quantize=awq"
EOF
    elif [ "$QUANTIZATION" == "gptq" ]; then
        cat >> "$TMP_FILE" << EOF
        - "--quantize=gptq"
EOF
    fi
fi

# Multi-GPU Parameter
if [ "$USE_GPU" == "true" ] && [ "$GPU_COUNT" -gt 1 ]; then
    cat >> "$TMP_FILE" << EOF
        - "--sharded=true"
EOF
    
    # Speziell für A100 bei Multi-GPU
    if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
        cat >> "$TMP_FILE" << EOF
        - "--num-shard=${GPU_COUNT}"
EOF
    fi
fi

# Umgebungsvariablen
cat >> "$TMP_FILE" << EOF
        env:
EOF

# GPU-spezifische Umgebungsvariablen
if [ "$USE_GPU" == "true" ]; then
    cat >> "$TMP_FILE" << EOF
        - name: CUDA_VISIBLE_DEVICES
          value: "${CUDA_DEVICES}"
EOF

    # A100-spezifische Umgebungsvariablen
    if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
        cat >> "$TMP_FILE" << EOF
        - name: NCCL_P2P_DISABLE
          value: "1"
        - name: NCCL_IB_DISABLE
          value: "1"
        - name: NCCL_DEBUG
          value: "INFO"
        - name: TGI_DISABLE_FLASH_ATTENTION
          value: "${DISABLE_FLASH_ATTENTION:-false}"
EOF
    fi
fi

# HuggingFace Token wenn vorhanden - jetzt korrekt gesetzt
if [ -n "$HUGGINGFACE_TOKEN" ]; then
    cat >> "$TMP_FILE" << EOF
        - name: HF_TOKEN
          value: "${HUGGINGFACE_TOKEN}"
        - name: HUGGING_FACE_HUB_TOKEN
          value: "${HUGGINGFACE_TOKEN}"
EOF
fi

# Container-Fortsetzung
cat >> "$TMP_FILE" << EOF
        ports:
        - containerPort: 8000
          protocol: TCP
        resources:
          limits:
            memory: "${MEMORY_LIMIT}"
            cpu: "${CPU_LIMIT}"
EOF

# GPU-Ressourcen
if [ "$USE_GPU" == "true" ]; then
    cat >> "$TMP_FILE" << EOF
            nvidia.com/gpu: ${GPU_COUNT}
EOF
fi

# Speicherressourcen anpassen für A100
if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
    cat >> "$TMP_FILE" << EOF
          requests:
            memory: "16Gi"
            cpu: "2"
EOF
fi

# Rest des YAML
cat >> "$TMP_FILE" << EOF
        volumeMounts:
        - name: model-cache
          mountPath: /data
        - name: dshm
          mountPath: /dev/shm
      volumes:
      - name: model-cache
        emptyDir: {}
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: ${DSHM_SIZE:-8Gi}
---
apiVersion: v1
kind: Service
metadata:
  name: ${TGI_SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: llm-server
spec:
  ports:
  - name: http
    port: 8000
    protocol: TCP
    targetPort: 8000
  selector:
    app: llm-server
  type: ClusterIP
EOF

# Anwenden der Konfiguration
echo "Deploying Text Generation Inference zu Namespace $NAMESPACE..."
echo "Verwendetes Modell: $MODEL_TO_USE"
echo "Verwendete GPU-Konfiguration: $GPU_TYPE mit $GPU_COUNT GPUs"
echo "Verwendete Konfiguration:"
cat "$TMP_FILE"
echo "---------------------------------"

kubectl apply -f "$TMP_FILE"

# Aufräumen
rm "$TMP_FILE"

# Warte auf das Deployment
echo "Warte auf das TGI Deployment..."
kubectl -n "$NAMESPACE" rollout status deployment/"$TGI_DEPLOYMENT_NAME" --timeout=300s

echo "TGI Deployment gestartet."
echo "Service erreichbar über: $TGI_SERVICE_NAME:8000"
echo
echo "HINWEIS: Verwendetes Modell: $MODEL_TO_USE"
echo "HINWEIS: TGI bietet eine OpenAI-kompatible API."
echo "HINWEIS: TGI Port 8000 wird direkt gemappt."
if [ "$GPU_TYPE" == "gpu-tesla-a100" ]; then
    echo "HINWEIS: Optimiert für Tesla A100 GPUs mit bfloat16 Präzision."
else
    echo "HINWEIS: Verwendet float16 Präzision für Standard-GPUs."
fi
echo "HINWEIS: TGI muss das Modell jetzt herunterladen, was einige Zeit dauern kann."
echo "Überwachen Sie den Fortschritt mit: kubectl -n $NAMESPACE logs -f deployment/$TGI_DEPLOYMENT_NAME"
echo
echo