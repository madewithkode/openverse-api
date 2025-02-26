set dotenv-load := false

IS_PROD := env_var_or_default("PROD", "")
IS_CI := env_var_or_default("CI", "")

# Show all available recipes
default:
  @just --list --unsorted


###########
# Helpers #
###########

# Sleep for given time showing the given message as long as given condition is met
@_loop condition message timeout="5m" time="5":
    timeout --foreground {{ timeout }} bash -c 'while [ {{ condition }} ]; do \
      echo "{{ message }}" && sleep {{ time }}; \
    done'; \
    EXIT_CODE=$?; \
    if [ $EXIT_CODE -eq 124 ]; then \
      echo "Timed out"; \
      exit $EXIT_CODE; \
    fi

##########
# Docker #
##########

DOCKER_FILE := "-f " + (
    if IS_PROD == "true" { "ingestion_server/docker-compose.yml" }
    else { "docker-compose.yml" }
)

export DOCKER_USER_ID := `id -u`
export DOCKER_GROUP_ID := `id -g`

# Run `docker-compose` configured with the correct files and environment
dc *args:
    docker-compose {{ DOCKER_FILE }} {{ args }}

# Build all (or specified) services
build *args:
    just dc build {{ args }}

# Bring all Docker services up
up *flags="":
    just dc up -d {{ flags }}

# Take all Docker services down
down flags="":
    just dc down {{ flags }}

# Recreate all volumes and containers from scratch
recreate:
    @just down -v
    @just up "--force-recreate --build"
    @just init

# Show logs of all, or named, Docker services
logs services="" args=(if IS_CI != "" { "" } else { "-f" }):
    just dc logs {{ args }} {{ services }}

# Attach to the specificed `service`. Enables interacting with the TTY of the running service.
attach service:
    docker attach $(docker-compose ps | grep {{ service }} | awk '{print $1}')

EXEC_DEFAULTS := if IS_CI == "" { "" } else { "-T" }

# Execute statement in service containers using Docker Compose
exec +args:
    docker-compose exec {{ EXEC_DEFAULTS }} {{ args }}

########
# Init #
########

# Create .env files from templates
env:
    cp api/env.template api/.env
    cp ingestion_server/env.template ingestion_server/.env

# Ensure all services are up and running
@_api-up:
    just up
    just wait-for-ing
    just wait-for-web

# Load sample data into the Docker Compose services
init: _api-up
    ./load_sample_data.sh


#######
# Dev #
#######

# Install Python dependencies in Pipenv environments
@install:
    just _api-install
    just _ing-install

# Setup pre-commit as a Git hook
precommit:
    cd api && pipenv run pre-commit install

# Run pre-commit to lint and reformat all files
lint:
    cd api && pipenv run pre-commit run --all-files

# Make locally trusted certificates
cert:
    mkdir -p nginx/certs/
    mkcert \
      -cert-file nginx/certs/openverse.crt \
      -key-file nginx/certs/openverse.key \
      dev.openverse.test localhost 127.0.0.1 ::1

#################
# Elasticsearch #
#################

# Check the health of Elasticsearch
@es-health es_host:
    -curl -s -o /dev/null -w '%{http_code}' 'http://{{ es_host }}/_cluster/health'

# Wait for Elasticsearch to be healthy
@wait-for-es es_host="localhost:50292":
    just _loop \
    '"$(just es-health {{ es_host }})" != "200"' \
    "Waiting for Elasticsearch to be healthy..."

@check-index index="image":
    -curl -sb -H "Accept:application/json" "http://localhost:50292/_cat/indices/{{ index }}" | grep -o "{{ index }}" | wc -l | xargs

# Wait for the media to be indexed in Elasticsearch
@wait-for-index index="image":
    just _loop \
    '"$(just check-index {{ index }})" != "1"' \
    "Waiting for index '{{ index }}' to be ready..."


####################
# Ingestion server #
####################

# Install dependencies for ingestion-server
_ing-install:
    cd ingestion_server && pipenv install --dev

# Perform the given action on the given model by invoking the ingestion-server API
_ing-api data port="50281":
    curl \
      -X POST \
      -H 'Content-Type: application/json' \
      -d '{{ data }}' \
      -w "\n" \
      'http://localhost:{{ port }}/task'

# Check the health of the ingestion-server
@ing-health ing_host:
    -curl -s -o /dev/null -w '%{http_code}' 'http://{{ ing_host }}/'

# Wait for the ingestion-server to be healthy
@wait-for-ing ing_host="localhost:50281":
    just _loop \
    '"$(just ing-health {{ ing_host }})" != "200"' \
    "Waiting for the ingestion-server to be healthy..."

# Load QA data into QA indices in Elasticsearch
@load-test-data model="image":
    just _ing-api '{"model": "{{ model }}", "action": "LOAD_TEST_DATA"}'

# Load sample data into temp table in API and new index in Elasticsearch
@ingest-upstream model="image" suffix="init":
    just _ing-api '{"model": "{{ model }}", "action": "INGEST_UPSTREAM", "index_suffix": "{{ suffix }}"}'

# Promote temp table to prod in API and new index to primary in Elasticsearch
@promote model="image" suffix="init" alias="image":
    just _ing-api '{"model": "{{ model }}", "action": "PROMOTE", "index_suffix": "{{ suffix }}", "alias": "{{ alias }}"}'

# Delete an index in Elasticsearch
@delete model="image" suffix="init" alias="image":
    just _ing-api '{"model": "{{ model }}", "action": "DELETE_INDEX", "index_suffix": "{{ suffix }}"}'

# Run ingestion-server tests locally
ing-testlocal *args:
    cd ingestion_server && pipenv run ./test/run_test.sh {{ args }}


#######
# API #
#######

# Install dependencies for API
_api-install:
    cd api && pipenv install --dev

# Check the health of the API
@web-health:
    -curl -s -o /dev/null -w '%{http_code}' 'http://localhost:50280/healthcheck/'

# Wait for the API to be healthy
@wait-for-web:
    just _loop \
    '"$(just web-health)" != "200"' \
    "Waiting for the API to be healthy..."

# Run smoke test for the API docs
api-doctest: _api-up
    curl --fail 'http://localhost:50280/v1/?format=openapi'

# Run API tests inside Docker
api-test *args: _api-up
    just exec web ./test/run_test.sh {{ args }}

# Run Django administrative commands locally
dj-local +args:
    cd api && pipenv run python manage.py {{ args }}

# Run Django administrative commands in the docker container
@dj +args="": _api-up
    just exec web python manage.py {{ args }}

# Make a test cURL request to the API
stats media="images":
    curl "http://localhost:50280/v1/{{ media }}/stats/"

# Get Django shell with IPython
ipython:
    just dj shell


##########
# Sphinx #
##########

# Compile Sphinx documentation into HTML output
sphinx-make: _api-up
    just exec web sphinx-build -M html docs/ build/

# Serve Sphinx documentation via a live-reload server
sphinx-live: _api-up
    just exec web sphinx-autobuild --host 0.0.0.0 --port 3000 docs/ build/html/

# Serve the Sphinx documentation from the HTML output directory
sphinx-serve dir="api" port="50231":
    cd {{ dir }}/build/html && pipenv run python -m http.server {{ port }}
