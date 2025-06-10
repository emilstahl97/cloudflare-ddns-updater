#!/bin/bash
## change to "bin/sh" when necessary

# Cloudflare credentials
auth_email=""                                       # The email used to login 'https://dash.cloudflare.com'
auth_method="token"                                 # Set to "global" for Global API Key or "token" for Scoped API Token
auth_key=""                                         # Your API Token or Global API Key
zone_identifier=""                                  # Can be found in the "Overview" tab of your domain

# Array of records to update (format: "record_name,ttl,proxy")
records=(
    "example.com,3600,false"
    "sub1.example.com,300,true"
    "sub2.example.com,300,false"
)

# Notification settings
sitename=""                                         # Title of site "Example Site"
slackchannel=""                                     # Slack Channel #example
slackuri=""                                         # URI for Slack WebHook "https://hooks.slack.com/services/xxxxx"
discorduri=""                                       # URI for Discord WebHook "https://discordapp.com/api/webhooks/xxxxx"

###########################################
## Check if we have a public IP
###########################################
ipv4_regex='([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])\.([01]?[0-9]?[0-9]|2[0-4][0-9]|25[0-5])'
ip=$(curl -s -4 https://cloudflare.com/cdn-cgi/trace | grep -E '^ip'); ret=$?
if [[ ! $ret == 0 ]]; then
    ip=$(curl -s https://api.ipify.org || curl -s https://ipv4.icanhazip.com)
else
    ip=$(echo $ip | sed -E "s/^ip=($ipv4_regex)$/\1/")
fi

if [[ ! $ip =~ ^$ipv4_regex$ ]]; then
    logger -s "DDNS Updater: Failed to find a valid IP."
    exit 2
fi

###########################################
## Check and set the proper auth header
###########################################
if [[ "${auth_method}" == "global" ]]; then
    auth_header="X-Auth-Key:"
else
    auth_header="Authorization: Bearer"
fi

###########################################
## Loop through each record
###########################################
for record_entry in "${records[@]}"; do
    # Parse record entry
    IFS=',' read -r record_name ttl proxy <<< "$record_entry"

    logger "DDNS Updater: Processing $record_name"

    ###########################################
    ## Seek for the A record
    ###########################################
    record=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records?type=A&name=$record_name" \
                        -H "X-Auth-Email: $auth_email" \
                        -H "$auth_header $auth_key" \
                        -H "Content-Type: application/json")

    ###########################################
    ## Check if the domain has an A record
    ###########################################
    if [[ $record == *"\"count\":0"* ]]; then
        logger -s "DDNS Updater: Record does not exist for $record_name, perhaps create one first? (${ip})"
        if [[ $slackuri != "" ]]; then
            curl -L -X POST $slackuri \
            --data-raw "{\"channel\": \"$slackchannel\", \"text\": \"$sitename DDNS: Record does not exist for $record_name (${ip}).\"}"
        fi
        if [[ $discorduri != "" ]]; then
            curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data-raw "{\"content\": \"$sitename DDNS: Record does not exist for $record_name (${ip}).\"}" $discorduri
        fi
        continue
    fi

    ###########################################
    ## Get existing IP
    ###########################################
    old_ip=$(echo "$record" | sed -E 's/.*"content":"(([0-9]{1,3}\.){3}[0-9]{1,3})".*/\1/')
    if [[ $ip == $old_ip ]]; then
        logger "DDNS Updater: IP ($ip) for $record_name has not changed."
        continue
    fi

    ###########################################
    ## Set the record identifier from result
    ###########################################
    record_identifier=$(echo "$record" | sed -E 's/.*"id":"([A-Za-z0-9_]+)".*/\1/')

    ###########################################
    ## Change the IP@Cloudflare using the API
    ###########################################
    update=$(curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_identifier/dns_records/$record_identifier" \
                         -H "X-Auth-Email: $auth_email" \
                         -H "$auth_header $auth_key" \
                         -H "Content-Type: application/json" \
                         --data "{\"type\":\"A\",\"name\":\"$record_name\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":${proxy}}")

    ###########################################
    ## Report the status
    ###########################################
    if [[ $update == *"\"success\":false"* ]]; then
        logger -s "DDNS Updater: $ip $record_name DDNS failed for $record_identifier ($ip). DUMPING RESULTS:\n$update"
        if [[ $slackuri != "" ]]; then
            curl -L -X POST $slackuri \
            --data-raw "{\"channel\": \"$slackchannel\", \"text\": \"$sitename DDNS Update Failed: $record_name: $record_identifier ($ip).\"}"
        fi
        if [[ $discorduri != "" ]]; then
            curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data-raw "{\"content\": \"$sitename DDNS Update Failed: $record_name: $record_identifier ($ip).\"}" $discorduri
        fi
    else
        logger "DDNS Updater: $ip $record_name DDNS updated."
        if [[ $slackuri != "" ]]; then
            curl -L -X POST $slackuri \
            --data-raw "{\"channel\": \"$slackchannel\", \"text\": \"$sitename Updated: $record_name\'s new IP Address is $ip\"}"
        fi
        if [[ $discorduri != "" ]]; then
            curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST \
            --data-raw "{\"content\": \"$sitename Updated: $record_name\'s new IP Address is $ip\"}" $discorduri
        fi
    fi
done

exit 0