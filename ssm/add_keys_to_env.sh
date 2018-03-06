#!/bin/bash

#TODO - remove
export REGION="ap-southeast-2"
#Run with $(basename $0) "/pipeline/${bamboo_application}-${bamboo_branch}-${bamboo_buildNumber}/" ./env.txt
# e.g. ./add_keys_to_env.sh "/pipeline/qm-develop-6/" ./env.txt && cat ./env.txt

#export ENV_OUTPUT_FILE=./env.txt

usage(){
  # print the error, if there is one
  if [[ -z "${1}" ]]
  then
    printf "\n==================================================================\n"
  else
    printf "\n=================================================================="
    printf "\n        Error: $1"
    printf "\n==================================================================\n\n"
  fi
  printf "\nDESCRIPTION: \n    Script retrieves all aws ssm parameters (with the given ssm hierarchy prefix (as \$1)\n"
  printf "\n        See https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-walk-hierarchies.html\n"
  printf "      and writes them to an env file that can be 'sourced' to add the keys to the ENV\n"
  printf "                     \n"
  printf "      The path will then be used to retrieve the keys from ssm\n"
  printf "      using the get-parameters-by-path cli command\n"
  printf "                     \n"
  printf "\nUSAGE:       \n    $(basename $0) <hierarchical path in ssm > <output file>\n"
  printf "\ne.g.\n     $(basename $0) \"/pipeline/myapp-develop-6/MySSMParameters/\" ./output.txt\n\n"
  printf "\n           Once the output file has been created, run 'source <output file> to add the vars to the shells ENV\n"
  printf "\nWHERE:\n"
  printf "    <hierarchical path in ssm:> see link above for more details on the hierarchical path strategy in AWS SSM\n"
  printf "\nASSUMPTIONS:\n"
  printf "    caller has permission to access the ssm keys at the given path\n"
  printf "    jq is installed (e.g. yum install jq)\n"
  printf "\n==================================================================\n"
  printf "\n\nMore details, have a look in the README :) \n\n"
  exit 1
}

#
# Invoke with 2 params - see usage above
#
validate_params() {
    if [[ "$#" -ne 2 ]]
    then
        usage "Missing parameters"
    fi
}



# Pre-requisites:
#    caller has permission to access the ssm keys at the given path
#    keys are stored in hierarchical fashion in AWS ssm parameter store
#        See https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-walk-hierarchies.html
#        e.g. /pipeline/myapp-develop-6/MySSMParameters/username
#    jq is installed (e.g. yum install jq)


#
# If we can't parse the given json ($1), just exit with a message and jq exit status as return code
#
validate_json() {
    if jq -e . >/dev/null 2>&1 <<<"${1}"; then
        echo "Parsed JSON successfully  "
    else
        local EXIT_STATUS=$?
        printf "Failed to parse JSON, or got false/null\nFor json\n---\n %s\n---\njq exit status %s\n" ${1} ${EXIT_STATUS}
        exit ${EXIT_STATUS}
    fi
}

#
# Create a file, containing environment variables, from each of the available keys in the SSM parameter store
#
# e.g. Given the following aws ssm cli command (and json response)
#
#   aws ssm get-parameters-by-path --path "/pipeline/myapp-develop-6/" --region ap-southeast-2 --recursive --with-decryption
#
#   {
#     "Parameters": [
#        {
#          "Type": "String",
#          "Name": "/pipeline/myapp-develop-6/MySSMParameters/username",
#          "Value": "lovemi"
#        },
#        {
#          "Type": "SecureString",
#          "Name": "/pipeline/myapp-develop-6/MySSMParameters/password",
#          "Value": "sOmeL0ngPassword"
#        }
#      ]
#    }
#
#  Expected Output
#    The SSM Parameter store JSON response would be transformed into a file containing
#
#     export username="lovemi"
#     export password="sOmeL0ngPassword"
#
#     nb: In the example above, the path prefix, "/pipeline/myapp-develop-6/MySSMParameters"
#         has been removed using the 'basename' command
#
#  params
#     $1 - The json response from above, as a single line string (see jq -c )
#     $2 - The path to write the expected output (see above) to.
#
function create_environment_key_file() {

    # Function uses a jq filter pipeline to build the expected output above from the aws ssm get parameters json response.
    # Breaking the jq filters below down: (see json example above)
    # For each entry in the Parameters array:
    #   Store the current key value pair as a jq var, called $key (so that we can refer to it again later)
    #   Split the Name param (e.g. myapp-develop-6/MySSMParameters/username )  by the delimiter '/'
    #   Get the split element at the last position, (.[-1]),  (using the example above, this will be 'username')
    #     (nb: This is the equivalent of the 'basename' command in unix e.g. basename "/tmp/blah.txt" returns "blah.txt")
    #   Replace any '-' with '_' (as '-' is invalid in ENV var names in bash
    #   Create each line of the output file e.g. "export username="lovemi"
    #   (nb: for those new to jq filters, the easiest way to 'grok' this jq filter pipeline is to run each filter individually)
    echo ${1} \
      | jq  -r '.Parameters[] | . as $key | .Name | split("/") | (.[-1]) | gsub("-"; "_")| "export \(.)=\"\($key |.Value)\""' \
      > ${2}

    printf "ssm keys output written to file at %s\n" ${2}
}


#
# Log the values to standard out (obfuscate any SecureString values)
#
function log_obfuscated_ssm_parameters() {
    printf "SSM Parameters response (OBFUSCATED)\n-------------------------------------\n"
    echo ${1} | jq -r '.Parameters[] | [.Name, if (.Type == "SecureString") then "*********" else .Value end] | join("=")'
    echo ""
}

validate_params $1 $2
export SSM_KEY_PREFIX=$1
export ENV_OUTPUT_FILE=$2

# Retrieve AWS REGION from the aws environment
# export REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.region')
#printf "aws ssm get-parameters-by-path --path "${SSM_KEY_PREFIX}" --region ${REGION} --recursive --with-decryption\n"
export SSM_JSON_RESPONSE=$(aws ssm get-parameters-by-path --path "${SSM_KEY_PREFIX}" --region ${REGION} --recursive --with-decryption)

export COMPACT_SSM_JSON_RESPONSE=$(echo ${SSM_JSON_RESPONSE} | jq -c '.')
validate_json "${COMPACT_SSM_JSON_RESPONSE}"

#
# Test the count of params returned (if no SSM parameters are returned, log a message and exit)
#
export PARAMS_COUNT=$(echo ${COMPACT_SSM_JSON_RESPONSE} | jq '.Parameters|length')
if (( ${PARAMS_COUNT} > 0 )); then
    echo "PARAMS=${PARAMS_COUNT}"
    log_obfuscated_ssm_parameters ${COMPACT_SSM_JSON_RESPONSE}
    create_environment_key_file ${COMPACT_SSM_JSON_RESPONSE} ${ENV_OUTPUT_FILE}
else
    printf "No Keys Returned from SSM for key hierarchy [${SSM_KEY_PREFIX}]"
fi



