docker run -it --rm \
    -v "${PWD}/scripts/autobahn-config:/config" \
    -v "${PWD}/.build/reports:/reports" \
    -p 9001:9001 \
    --network=host \
    --name fuzzingclient \
    crossbario/autobahn-testsuite wstest -m fuzzingclient -s /config/fuzzingclient.json
