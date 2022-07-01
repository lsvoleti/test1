#!/usr/bin/env bash
#
# Run scripts on Azure VM using Custom Script Extension Version 2.
#
# Required globals:
#   AZURE_APP_ID
#   AZURE_PASSWORD
#   AZURE_TENANT_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_VM_NAME
#   AZURE_EXTENSION_COMMAND
#
# Optional globals:
#   AZURE_EXTENSION_FILES
#   AZURE_FORCE_UPDATE
#   AZURE_NO_WAIT
#   AZURE_CLEANUP
#   EXTRA_ARGS
#   DEBUG

source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/uploadfile.sh"

enable_debug


$AZURE_APP_ID=$(az account show --query tenantId -o tsv)
$AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

# mandatory parameters
AZURE_APP_ID=${AZURE_APP_ID:?'AZURE_APP_ID variable missing.'}
AZURE_PASSWORD=${AZURE_PASSWORD:?'AZURE_PASSWORD variable missing.'}
AZURE_TENANT_ID=${AZURE_TENANT_ID:?'AZURE_TENANT_ID variable missing.'}
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:?'AZURE_RESOURCE_GROUP variable missing.'}
AZURE_VM_NAME=${AZURE_VM_NAME:?'AZURE_VM_NAME variable missing.'}
AZURE_EXTENSION_COMMAND=${AZURE_EXTENSION_COMMAND:?'AZURE_EXTENSION_COMMAND variable missing.'}

debug AZURE_APP_ID: "${AZURE_APP_ID}"
debug AZURE_TENANT_ID: "${AZURE_TENANT_ID}"
debug AZURE_RESOURCE_GROUP: "${AZURE_RESOURCE_GROUP}"
debug AZURE_VM_NAME: "${AZURE_RESOURCE_GROUP}"
debug AZURE_EXTENSION_NAME: "${AZURE_RESOURCE_GROUP}"
debug AZURE_EXTENSION_COMMAND: "${AZURE_EXTENSION_COMMAND}"

# auth
AUTH_ARGS_STRING="--username ${AZURE_APP_ID} --password ${AZURE_PASSWORD} --tenant ${AZURE_TENANT_ID}"

if [[ "${DEBUG}" == "true" ]]; then
  AUTH_ARGS_STRING="${AUTH_ARGS_STRING} --debug"
fi

AUTH_ARGS_STRING="${AUTH_ARGS_STRING} ${EXTRA_ARGS:=""}"

debug AUTH_ARGS_STRING: "${AUTH_ARGS_STRING}"

info "Signing in..."

run az login --service-principal ${AUTH_ARGS_STRING}

# deployment
AZURE_EXTENSION_PUBLISHER="Microsoft.Azure.Extensions"
AZURE_EXTENSION_NAME="CustomScript"
AZURE_EXTENSION_VERSION="2.0"
ARGS_STRING="--resource-group ${AZURE_RESOURCE_GROUP} --vm-name ${AZURE_VM_NAME} --name ${AZURE_EXTENSION_NAME} --publisher ${AZURE_EXTENSION_PUBLISHER} --version ${AZURE_EXTENSION_VERSION} --verbose"

if [[ -z "${AZURE_EXTENSION_FILES}" ]]; then
  # command to execute doesn't require any external files

  # --protected-settings also accepts JSON formatted strings, but az fails if e.g. commandToExecute contain spaces.
  # So we are using an intermediary .json file to be able to pass any string to e.g. commandToExecute.
  echo "{\"commandToExecute\":\"$AZURE_EXTENSION_COMMAND\"}" > protected-settings.json
else
  # command to execute requires external files

  # get resource group location
  LOCATION=$(az group show --name $AZURE_RESOURCE_GROUP --query location | sed 's/[[:punct:]\t]//g')
  if [[ -z "${LOCATION}" ]]; then
    fail "'${AZURE_RESOURCE_GROUP}' Resource Group doesn't exist"
  fi

  # get virtual machine id
  VM_ID=$(az vm show -g $AZURE_RESOURCE_GROUP -n $AZURE_VM_NAME --query vmId)
  if [[ -z "${VM_ID}" ]]; then
    fail "'${AZURE_VM_NAME}' Virtual Machine doesn't exist"
  fi

  # use vm id to create a unique name for storage account
  VM_ID_STRIPPED=$(echo $VM_ID | sed 's/[[:punct:]\t]//g' | head -c 10)
  PIPE_VM_STORAGE_ACCOUNT_NAME="bbpipe${VM_ID_STRIPPED}"

  # ensure storage account exists before deployment
  if [ "$(az storage account check-name --name $PIPE_VM_STORAGE_ACCOUNT_NAME --query nameAvailable)" = "true" ]; then
      info "Creating Storage Account '${PIPE_VM_STORAGE_ACCOUNT_NAME}'..."
      run az storage account create --location $LOCATION --name $PIPE_VM_STORAGE_ACCOUNT_NAME --resource-group $AZURE_RESOURCE_GROUP --sku Standard_LRS
  else
      info "Using '${PIPE_VM_STORAGE_ACCOUNT_NAME}' Storage Account to store deployment artifacts"
  fi

  # ensure blob storage container exists before deployment
  CONTAINER_NAME="blob${VM_ID_STRIPPED}"

  if [ "$(az storage container exists --name $CONTAINER_NAME --account-name $PIPE_VM_STORAGE_ACCOUNT_NAME --query exists)" = "false" ];  then
      info "Creating Blob Storage Container '${CONTAINER_NAME}'..."
      run az storage container create --name $CONTAINER_NAME --account-name $PIPE_VM_STORAGE_ACCOUNT_NAME
  else
      info "Using '${CONTAINER_NAME}' Blob Container in '${PIPE_VM_STORAGE_ACCOUNT_NAME}' Storage Account to store deployment artifacts"
  fi

  # upload all local files to blob storage container
  upload_all ${AZURE_EXTENSION_FILES} ${PIPE_VM_STORAGE_ACCOUNT_NAME} ${CONTAINER_NAME}

  echo "{\"fileUris\":[${UPLOAD_RESULT}],\"commandToExecute\":\"$AZURE_EXTENSION_COMMAND\"}" > protected-settings.json
fi

info "Temporary file 'protected-settings.json' has been created"
cat protected-settings.json

ARGS_STRING="${ARGS_STRING} --protected-settings protected-settings.json"

if [[ "${AZURE_FORCE_UPDATE}" == "true" ]]; then
  ARGS_STRING="${ARGS_STRING} --force-update"
fi

if [[ "${AZURE_NO_WAIT}" == "true" ]]; then
  ARGS_STRING="${ARGS_STRING} --no-wait"
fi

if [[ "${DEBUG}" == "true" ]]; then
  ARGS_STRING="${ARGS_STRING} --debug"
fi

ARGS_STRING="${ARGS_STRING} ${EXTRA_ARGS:=""}"

debug ARGS_STRING: "${ARGS_STRING}"

info "Starting deployment of Custom Script Extension Version 2 to Azure VM..."
run az vm extension set ${ARGS_STRING}

# optional cleanup
if [[ "${AZURE_CLEANUP}" == "true" ]]; then
  info "Deleting '${PIPE_VM_STORAGE_ACCOUNT_NAME}' Storage Account..."
  run az storage account delete --name ${PIPE_VM_STORAGE_ACCOUNT_NAME} -g ${AZURE_RESOURCE_GROUP} --y
fi

if [ "${status}" -eq 0 ]; then
  success "Deployment successful."
else
  fail "Deployment failed."
fi
