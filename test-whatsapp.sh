#!/bin/bash
set -a
source .env.local
set +a

if [ -z "$WHATSAPP_PHONE_NUMBER_ID" ] || [ -z "$WHATSAPP_ACCESS_TOKEN" ]; then
  echo "ERROR: env vars not loaded. Check .env.local"
  exit 1
fi

echo "Using Phone Number ID: $WHATSAPP_PHONE_NUMBER_ID"
echo "Sending test template..."

curl -s -X POST "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_NUMBER_ID}/messages" \
  -H "Authorization: Bearer ${WHATSAPP_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "messaging_product": "whatsapp",
    "to": "919758041970",
    "type": "template",
    "template": {
      "name": "registration",
      "language": { "code": "en_US" },
      "components": [
        {
          "type": "body",
          "parameters": [
            { "type": "text", "text": "Test Patient" },
            { "type": "text", "text": "VEH000001" }
          ]
        }
      ]
    }
  }' | python3 -m json.tool

echo ""
echo "Done."
