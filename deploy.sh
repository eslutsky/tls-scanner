#!/bin/bash
# A script to build, deploy, and run the OpenShift scanner application.
#
# Usage: ./deploy.sh [action]
# Actions:
#   build          - Build the container image.
#   push           - Push the container image to a registry.
#   deploy         - Deploy the scanner as a Kubernetes Job.
#   cleanup        - Remove all scanner-related resources.
#   full-deploy    - Run build, push, and deploy actions.
#   (no action)    - Run a full-deploy and then cleanup.

# --- Configuration ---
APP_NAME="tls-scanner"
# Default image name, can be overridden by environment variable SCANNER_IMAGE
SCANNER_IMAGE=${SCANNER_IMAGE:-"quay.io/user/tls-scanner:latest"}
# Namespace to deploy to, can be overridden by NAMESPACE env var
NAMESPACE=${NAMESPACE:-$(oc project -q)}
JOB_TEMPLATE="scanner-job.yaml.template"
JOB_NAME="tls-scanner-job"

# --- Functions ---

# Function to print a formatted header
print_header() {
    echo "========================================================================"
    echo "=> $1"
    echo "========================================================================"
}

# Function to check if a command exists
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo "Error: Required command '$1' is not installed or not in PATH."
        exit 1
    fi
}

# Function to check the last command's exit status
check_error() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed."
        exit 1
    fi
}

build_image() {
    print_header "Step 1: Building Container Image"
    check_command "podman" || check_command "docker"
    check_command "go"

    echo "--> Building Go binary..."
    CGO_ENABLED=0 GOOS=linux go build -o tls-scanner .
    check_error "Go build"

    echo "--> Building container image: ${SCANNER_IMAGE}"
    if command -v podman &> /dev/null; then
        podman build -t ${SCANNER_IMAGE} .
        check_error "Podman build"
    elif command -v docker &> /dev/null; then
        docker build -t ${SCANNER_IMAGE} .
        check_error "Docker build"
    fi
    echo "--> Image built: ${SCANNER_IMAGE}"
}

push_image() {
    print_header "Step 2: Pushing Container Image"
    check_command "podman" || check_command "docker"

    echo "--> Pushing container image: ${SCANNER_IMAGE}"
    if command -v podman &> /dev/null; then
        podman push ${SCANNER_IMAGE}
        check_error "Podman push"
    elif command -v docker &> /dev/null; then
        docker push ${SCANNER_IMAGE}
        check_error "Docker push"
    fi
    echo "--> Image pushed: ${SCANNER_IMAGE}"
}

deploy_scanner_job() {
    print_header "Step 3: Deploying Scanner Job"
    check_command "oc"

    if [ -z "$NAMESPACE" ]; then
        echo "Error: Could not determine OpenShift project. Please set NAMESPACE or run 'oc project <name>'."
        exit 1
    fi
    echo "--> Deploying to namespace: ${NAMESPACE}"

    echo "--> Ensuring 'default' ServiceAccount exists in namespace '${NAMESPACE}'..."
    oc get sa default -n "$NAMESPACE" &> /dev/null || oc create sa default -n "$NAMESPACE"
    check_error "Creating ServiceAccount"

    echo "--> Granting 'cluster-reader' ClusterRole to 'default' ServiceAccount..."
    oc adm policy add-cluster-role-to-user cluster-reader -z default -n "$NAMESPACE"
    check_error "Adding cluster-reader role"

    echo "--> Granting 'privileged' SCC to 'default' ServiceAccount..."
    oc adm policy add-scc-to-user privileged -z default -n "$NAMESPACE"
    check_error "Adding privileged SCC"

    echo "--> Creating ClusterRole 'tls-scanner-cross-namespace' for cross-namespace resource access..."
cat <<EOF | oc apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: tls-scanner-cross-namespace
rules:
- apiGroups:
  - ""
  resources:
  - pods/exec
  verbs:
  - create
- apiGroups:
  - operator.openshift.io
  resources:
  - ingresscontrollers
  verbs:
  - get
  - list
- apiGroups:
  - machineconfiguration.openshift.io
  resources:
  - kubeletconfigs
  verbs:
  - get
  - list
EOF
    check_error "Creating tls-scanner-cross-namespace ClusterRole"

    echo "--> Binding 'tls-scanner-cross-namespace' ClusterRole to 'default' ServiceAccount..."
    oc adm policy add-cluster-role-to-user tls-scanner-cross-namespace -z default -n "$NAMESPACE"
    check_error "Binding tls-scanner-cross-namespace ClusterRole"

    echo "--> Copying global pull secret to allow image pulls from CI registry..."
    oc get secret pull-secret -n openshift-config -o yaml | sed "s/namespace: .*/namespace: $NAMESPACE/" | oc apply -n "$NAMESPACE" -f -
    check_error "Copying pull secret"
    oc secrets link default pull-secret --for=pull -n "$NAMESPACE"
    check_error "Linking pull secret"

    echo "--> Applying Job manifest from template: ${JOB_TEMPLATE}"
    if [ ! -f "$JOB_TEMPLATE" ]; then
        echo "Error: Job template file not found: ${JOB_TEMPLATE}"
        exit 1
    fi
    
    # Substitute environment variables in the template and apply it
    sed -e "s|\\\${SCANNER_IMAGE}|${SCANNER_IMAGE}|g" -e "s|\\\${NAMESPACE}|${NAMESPACE}|g" -e "s|\\\${JOB_NAME}|${JOB_NAME}|g" "$JOB_TEMPLATE" | oc apply -f -
    check_error "Applying Job manifest"

    echo "--> Scanner Job '${JOB_NAME}' deployed."
    
    echo "--> Waiting for scanner pod to be created and start running..."
    POD_RUNNING=false
    # Wait up to 10 minutes (60 * 10s) for the pod to start.
    for i in {1..60}; do
        POD_NAME=$(oc get pods -n "${NAMESPACE}" -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -z "$POD_NAME" ]; then
            echo "    Pod for job not created yet. Waiting... (${i}/60)"
            sleep 10
            continue
        fi

        POD_PHASE=$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        
        if [ "$POD_PHASE" = "Running" ]; then
            echo "--> Pod '${POD_NAME}' is now running."
            POD_RUNNING=true
            break
        elif [ "$POD_PHASE" = "Failed" ] || [ "$POD_PHASE" = "Error" ]; then
            echo "Error: Pod '${POD_NAME}' failed to start. Final phase: $POD_PHASE"
            echo "--- Describing failed pod for details ---"
            oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
            echo "--- End of pod description ---"
            exit 1
        elif [ "$POD_PHASE" = "Succeeded" ]; then
             echo "--> Pod '${POD_NAME}' completed very quickly. Assuming success and proceeding to wait for job completion."
             POD_RUNNING=true
             break
        else
            echo "    Pod status is '${POD_PHASE}'. Waiting... (${i}/60)"
            # Check for common container-level waiting issues
            REASON=$(oc get pod "${POD_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
            if [ -n "$REASON" ]; then
                 echo "    Container waiting reason: ${REASON}. This may indicate an image pull or configuration issue."
            fi
            sleep 10
        fi
    done

    if ! $POD_RUNNING; then
        echo "Error: Pod did not start running within 10 minutes."
        if [ -n "$POD_NAME" ]; then
            echo "--- Describing non-running pod for details ---"
            oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
            echo "--- End of pod description ---"
        else
            echo "--- No pod was created for the job. Describing job for details ---"
            oc describe job "${JOB_NAME}" -n "${NAMESPACE}"
            echo "--- End of job description ---"
        fi
        exit 1
    fi

    echo "--> To monitor logs, run: oc logs -f job/${JOB_NAME} -n ${NAMESPACE}"
    echo "--> Waiting for job to complete... (timeout: 3h)"

    # Wait for the job to complete
    if ! oc wait --for=condition=complete "job/${JOB_NAME}" -n "${NAMESPACE}" --timeout=3h; then
        echo "Error: Job '${JOB_NAME}' did not complete within the 3h timeout."
        echo "--- Final job status ---"
        oc describe job "${JOB_NAME}" -n "${NAMESPACE}"
        echo "--- Final pod status ---"
        POD_NAME=$(oc get pods -n "${NAMESPACE}" -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$POD_NAME" ]; then
            oc describe pod "${POD_NAME}" -n "${NAMESPACE}"
            echo "--- Scanner pod logs ---"
            oc logs "pod/${POD_NAME}" -n "${NAMESPACE}"
        fi
        exit 1
    fi

    echo "--> Job '${JOB_NAME}' completed successfully."
    
    echo "--> Copying artifacts from completed pod..."
    # Find the pod created by the job
    POD_NAME=$(oc get pods -n "${NAMESPACE}" -l job-name=${JOB_NAME} -o jsonpath='{.items[0].metadata.name}')
    check_error "Finding completed pod"

    # Create a local directory for artifacts
    mkdir -p ./artifacts

    # Copy files from the pod
    oc cp "${NAMESPACE}/${POD_NAME}:/artifacts/results.json" "./artifacts/results.json"
    check_error "Copying results.json"
    oc cp "${NAMESPACE}/${POD_NAME}:/artifacts/results.csv" "./artifacts/results.csv"
    check_error "Copying results.csv"
    oc cp "${NAMESPACE}/${POD_NAME}:/artifacts/scan.log" "./artifacts/scan.log"
    check_error "Copying scan.log"

    echo "--> Artifacts copied to ./artifacts directory."
}

cleanup() {
    print_header "Step 4: Cleaning Up"
    check_command "oc"

    echo "--> Removing ClusterRoleBinding for 'cluster-reader'..."
    oc adm policy remove-cluster-role-from-user cluster-reader -z default -n "$NAMESPACE" || true
    echo "--> Removing ClusterRoleBinding for 'tls-scanner-cross-namespace'..."
    oc adm policy remove-cluster-role-from-user tls-scanner-cross-namespace -z default -n "$NAMESPACE" || true
    echo "--> Removing SCC 'privileged' from ServiceAccount..."
    oc adm policy remove-scc-from-user privileged -z default -n "$NAMESPACE" || true
    echo "--> Deleting ClusterRole 'tls-scanner-cross-namespace'..."
    oc delete clusterrole tls-scanner-cross-namespace --ignore-not-found=true
    echo "--> Deleting Job '${JOB_NAME}'..."
    oc delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found=true
    echo "--> Deleting copied pull secret..."
    oc delete secret pull-secret -n "$NAMESPACE" --ignore-not-found=true
    
    echo "--> Cleanup complete."
}

# --- Main Logic ---
ACTION=$1

case "$ACTION" in
    build)
        build_image
        ;;
    push)
        push_image
        ;;
    deploy)
        deploy_scanner_job
        ;;
    cleanup)
        cleanup
        ;;
    full-deploy)
        build_image
        push_image
        deploy_scanner_job
        ;;
    *)
        echo "No action specified, running full-deploy and cleanup."
        build_image
        push_image
        deploy_scanner_job
        cleanup
        ;;
esac

