#!/bin/sh
# Entrypoint: expand SLACK_WEBHOOK_URL in config using sed, then exec alertmanager
echo "Expanding SLACK_WEBHOOK_URL in alertmanager config..."
sed "s|\${SLACK_WEBHOOK_URL}|${SLACK_WEBHOOK_URL}|g" \
    /etc/alertmanager/alertmanager.yml \
    > /etc/alertmanager/alertmanager-expanded.yml
echo "Config expanded successfully."
echo "Starting alertmanager..."
exec /bin/alertmanager --config.file=/etc/alertmanager/alertmanager-expanded.yml "$@"
