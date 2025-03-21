#!/bin/bash

# Skript zum Deployment der Open WebUI für Text Generation Inference (TGI) mit Transformers-Integration
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

# Erstelle temporäre YAML-Datei für das Deployment
TMP_FILE=$(mktemp)

# WebUI-Konfiguration mit TGI_API_KEY
if [ -n "$TGI_API_KEY" ]; then
    WEBUI_API_KEY_ENV="
            - name: OPENAI_API_KEY
              value: \"${TGI_API_KEY}\""
else
    WEBUI_API_KEY_ENV=""
fi

# Erstelle YAML für WebUI Deployment
cat << EOF > "$TMP_FILE"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $WEBUI_DEPLOYMENT_NAME
  namespace: $NAMESPACE
  labels:
    service: tgi-webui
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      service: tgi-webui
  template:
    metadata:
      labels:
        service: tgi-webui
    spec:
      containers:
        - image: ghcr.io/open-webui/open-webui:main
          name: webui
          env:
            - name: ENABLE_OLLAMA_API
              value: "false"
            - name: OPENAI_API_BASE_URL
              value: "http://$TGI_SERVICE_NAME:8000/v1"$WEBUI_API_KEY_ENV
            - name: ENABLE_RAG_WEB_SEARCH
              value: "false"
            - name: ENABLE_IMAGE_GENERATION
              value: "false"
EOF

# Transformers-spezifische Umgebungsvariablen für WebUI hinzufügen
if [ "${ENABLE_TRANSFORMERS:-false}" == "true" ]; then
    cat << EOF >> "$TMP_FILE"
            # Transformers-Integration
            - name: MODEL_ID
              value: "$MODEL_NAME"
            - name: DEFAULT_MODEL
              value: "$MODEL_NAME"
            - name: OPENAI_SHOW_MODEL_SELECTION
              value: "true"
            - name: OPENAI_API_DISABLE_HISTORY
              value: "false"
            - name: MODEL_CONTEXT_WINDOW
              value: "${MAX_TOTAL_TOKENS:-8192}"
EOF

    # Erweiterte Transformers-Parameter
    if [ -n "$MAX_BATCH_SIZE" ]; then
        cat << EOF >> "$TMP_FILE"
            - name: BATCH_SIZE
              value: "${MAX_BATCH_SIZE}"
EOF
    fi
    
    # HuggingFace-Token wenn konfiguriert
    if [ -n "$HUGGINGFACE_TOKEN" ]; then
        cat << EOF >> "$TMP_FILE"
            - name: HF_TOKEN
              value: "${HUGGINGFACE_TOKEN}"
            - name: HUGGING_FACE_HUB_TOKEN
              value: "${HUGGINGFACE_TOKEN}"
EOF
    fi
fi

# Container-Fortsetzung
cat << EOF >> "$TMP_FILE"
          ports:
            - containerPort: 3000
              protocol: TCP
          resources:
            limits:
              memory: "2Gi"
              cpu: "1000m"
          volumeMounts:
            - name: webui-data
              mountPath: /app/backend/data
EOF

# Falls Transformers aktiviert ist, Cache-Volume hinzufügen
if [ "${ENABLE_TRANSFORMERS:-false}" == "true" ]; then
    cat << EOF >> "$TMP_FILE"
            - name: transformers-cache
              mountPath: /app/backend/transformers-cache
EOF
fi

# Volumes
cat << EOF >> "$TMP_FILE"
      volumes:
        - name: webui-data
          emptyDir: {}
EOF

# Falls Transformers aktiviert ist, Cache-Volume hinzufügen
if [ "${ENABLE_TRANSFORMERS:-false}" == "true" ]; then
    cat << EOF >> "$TMP_FILE"
        - name: transformers-cache
          emptyDir: {}
EOF
fi

# Service
cat << EOF >> "$TMP_FILE"
---
apiVersion: v1
kind: Service
metadata:
  name: $WEBUI_SERVICE_NAME
  namespace: $NAMESPACE
  labels:
    service: tgi-webui
spec:
  ports:
    - name: http
      port: 3000
      protocol: TCP
      targetPort: 3000
  selector:
    service: tgi-webui
  type: ClusterIP
EOF

# Anwenden der Konfiguration
echo "Deploying Open WebUI to namespace $NAMESPACE..."
echo "Rollout-Strategie: Recreate (100% Ressourcennutzung)"

# Zeige Transformers-Status an
if [ "${ENABLE_TRANSFORMERS:-false}" == "true" ]; then
    echo "Transformers-Integration: AKTIVIERT"
    echo "  - Modell: $MODEL_NAME"
    echo "  - Kontextfenster: ${MAX_TOTAL_TOKENS:-8192}"
    if [ -n "$MAX_BATCH_SIZE" ]; then
        echo "  - Batch-Größe: $MAX_BATCH_SIZE"
    fi
fi

echo "Verwendete Konfiguration:"
cat "$TMP_FILE"
echo "---------------------------------"

kubectl apply -f "$TMP_FILE"

# Aufräumen
rm "$TMP_FILE"

# Warte auf das Deployment
echo "Warte auf das WebUI Deployment..."
kubectl -n "$NAMESPACE" rollout status deployment/"$WEBUI_DEPLOYMENT_NAME" --timeout=300s

echo "Open WebUI Deployment erfolgreich."
echo "Service erreichbar über: $WEBUI_SERVICE_NAME:3000"
echo
echo "HINWEIS: Die WebUI verbindet sich automatisch mit dem TGI-Server über die OpenAI-kompatible API."
if [ "${ENABLE_TRANSFORMERS:-false}" == "true" ]; then
    echo "HINWEIS: Transformers-Integration ist aktiviert für erweiterte Modellkontrolle."
    echo "HINWEIS: Sie können die erweiterten Modellparameter in der WebUI-Einstellung konfigurieren."
fi
echo "Überwachen Sie den Status mit: kubectl -n $NAMESPACE get pods"
echo "Für direkten Zugriff führen Sie aus: kubectl -n $NAMESPACE port-forward svc/$WEBUI_SERVICE_NAME 3000:3000"
