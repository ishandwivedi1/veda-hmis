#!/bin/bash
set -a
source .env.local
set +a

echo "Using Phone Number ID: $WHATSAPP_PHONE_NUMBER_ID"
echo "Sending test 'payment' template..."

curl -s -X POST "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_NUMBER_ID}/messages" \
  -H "Authorization: Bearer ${WHATSAPP_ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "messaging_product": "whatsapp",
    "to": "919758041970",
    "type": "template",
    "template": {
      "name": "payment",
      "language": { "code": "en_US" },
      "components": [
        {
          "type": "body",
          "parameters": [
            { "type": "text", "text": "Test Patient" },
            { "type": "text", "text": "5,000.00" },
            { "type": "text", "text": "RCT26-000099" },
            { "type": "text", "text": "02 Aug 2026" }
          ]
        }
      ]
    }
  }' | python3 -m json.tool
