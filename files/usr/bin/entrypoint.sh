#!/bin/bash

if [[ $BUNDLE_DEBUG == "true" ]]; then
    set -x
fi

# Work-Around
# The OpenShift's s2i (source to image) requires that no ENTRYPOINT exist
# for any of the s2i builder base images.  Our 's2i-apb' builder uses the
# apb-base as it's base image.  But since the apb-base defines its own
# entrypoint.sh, it is not compatible with the current source-to-image.
#
# The below work-around checks if the entrypoint was called within the
# s2i-apb's 'assemble' script process. If so, it skips the rest of the steps
# which are APB run-time specific.
#
# Details of the issue in the link below:
# https://github.com/openshift/source-to-image/issues/475
#
if [[ $@ == *"s2i/assemble"* ]]; then
  echo "---> Performing S2I build... Skipping server startup"
  exec "$@"
  exit $?
fi

ACTION=$1
shift
mv /opt/apb/actions /opt/apb/project
playbooks="/opt/apb/project"
CREDS="/var/tmp/bind-creds"
SECRETS_DIR="/etc/apb-secrets"
TEST_RESULT="/var/tmp/test-result"
ROLE_NAME=$(echo $2 | jq -r .role_name 2>/dev/null || echo "null")
ROLE_NAMESPACE=$(echo $2 | jq -r .role_name 2>/dev/null || echo "null")
MOUNTED_SECRETS=$(ls $SECRETS_DIR)

if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "${USER_NAME:-apb}:x:$(id -u):0:${USER_NAME:-apb} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

extra_args="${@}"
if [[ ! -z "$MOUNTED_SECRETS" ]] ; then
  echo '---' > /opt/apb/env/passwords

  for key in ${MOUNTED_SECRETS} ; do
    for file in $(ls ${SECRETS_DIR}/${key}/..data); do
      echo "$file: $(cat ${SECRETS_DIR}/${key}/..data/${file})" >> /opt/apb/env/passwords
    done
  done
  extra_args="${extra_args} --extra-vars no_log=true"
fi

echo "${extra_args}" > /opt/apb/env/cmdline

# Install role from galaxy
if [[ $ROLE_NAME != "null" ]] && [[ $ROLE_NAMESPACE != "null" ]]; then
  ansible-galaxy install -s https://galaxy-qa.ansible.com $ROLE_NAMESPACE.$ROLE_NAME -p /opt/ansible/roles
  mv /opt/ansible/roles/$ROLE_NAMESPACE.$ROLE_NAME /opt/ansible/roles/$ROLE_NAME
  mv /opt/ansible/roles/$ROLE_NAME/playbooks $playbooks
fi

if [[ -e "$playbooks/$ACTION.yaml" ]]; then
  PLAYBOOK="$playbooks/$ACTION.yaml"
elif [[ -e "$playbooks/$ACTION.yml" ]]; then
  PLAYBOOK="$playbooks/$ACTION.yml"
else
  echo "'$ACTION' NOT IMPLEMENTED" # TODO
  exit 8 # action not found
fi

# Invoke ansible-runner
ansible-runner run --playbook $PLAYBOOK /opt/apb

EXIT_CODE=$?

set +e
rm -f /tmp/secrets
set -e

if [ -f $TEST_RESULT ]; then
  test-retrieval-init
fi

exit $EXIT_CODE
