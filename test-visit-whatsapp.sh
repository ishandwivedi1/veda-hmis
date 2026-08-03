#!/bin/bash
set -a
source .env.local
set +a

echo "Using Phone Number ID: $WHATSAPP_PHONE_NUMBER_ID"
echo "Sending test 'appointment' template..."

curl -s -X POST "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_NUMBER_ID}/messages" \
  -H "Authorization: Bearer ${WHATSAPP_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "messaging_product": "whatsapp",
    "to": "919758041970",
    "type": "template",
    "template": {
      "name": "appointment",
      "language": { "code": "en_US" },
      "components": [
        {
          "type": "body",
          "parameters": [
            { "type": "text", "text": "Test Patient" },
            { "type": "text", "text": "V26-000099" },
            { "type": "text", "text": "01 Aug 2026, 05:30 PM" }
          ]
        }
      ]
    }
  }' | python3 -m json.tool
