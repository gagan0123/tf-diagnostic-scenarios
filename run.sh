#!/bin/bash

# --- Helper Functions ---

# Function to print error messages
print_error() {
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "[ERROR] $1"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo
}

# Function to print success messages
print_success() {
    echo "**************************************"
    echo "[SUCCESS] $1"
    echo "**************************************"
}

# Function to print info messages
print_info() {
    echo
    echo "--------------------------------------"
    echo "[INFO] $1"
    echo "--------------------------------------"
}

# --- Prerequisite and Configuration Functions ---

# Check for required command-line tools
check_dependencies() {
    print_info "Checking dependencies..."
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform could not be found. Please install it first."
        exit 1
    fi
    if ! command -v gcloud &> /dev/null; then
        print_error "gcloud could not be found. Please install it first."
        exit 1
    fi
    print_success "All dependencies are installed."
}

# Load config from .env file, gcloud config, or prompt user
load_or_create_config() {
    if [ -f ".env" ]; then
        print_info "Loading configuration from .env file."
        export $(grep -v '^#' .env | xargs)
    else
        print_info "No .env file found. Trying to get configuration from gcloud..."

        PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
        REGION=$(gcloud config get-value compute/region 2>/dev/null)

        if [ -n "$PROJECT_ID" ]; then
            read -p "Auto-detected Project ID: ${PROJECT_ID}. Use this? (y/n): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                read -p "Enter your GCP Project ID: " PROJECT_ID
            fi
        else
            print_info "Could not determine Project ID from gcloud config."
            read -p "Enter your GCP Project ID: " PROJECT_ID
        fi

        if [ -z "$REGION" ]; then
            print_info "Could not determine Region from gcloud config."
            read -p "Enter the default GCP Region (e.g., us-central1) [us-central1]: " REGION
        fi
        : "${REGION:=us-central1}"

        if [ -z "$PROJECT_ID" ] || [ -z "$REGION" ]; then
            print_error "Project ID and Region are required. Exiting."
            exit 1
        fi

        echo "PROJECT_ID=${PROJECT_ID}" > .env
        echo "REGION=${REGION}" >> .env
        print_success "Configuration saved to .env file for future runs."
        export PROJECT_ID
        export REGION
    fi
}

# Check gcloud authentication status
check_gcloud_auth() {
    print_info "Checking gcloud authentication status..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then
        print_error "You are not authenticated with gcloud. Please run 'gcloud auth login' and 'gcloud config set project <YOUR_PROJECT_ID>'."
        exit 1
    fi
    local active_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
    print_success "Authenticated with gcloud as: ${active_account}"
}

# --- Scenario and Terraform Functions ---

# Prompt for and save scenario-specific variables
get_scenario_vars() {
    local scenario_num=$1

    case $scenario_num in
        2)
            if [ -z "$ZONE" ]; then
                read -p "Enter the Zone for the GCE instance (e.g., ${REGION}-a) [${REGION}-a]: " ZONE
                echo "ZONE=${ZONE}" >> .env
                export ZONE
            fi
            : "${ZONE:=${REGION}-a}"
            if [ -z "$DOMAIN_NAME" ]; then
                read -p "Enter a domain name (e.g., example.com): " DOMAIN_NAME
                echo "DOMAIN_NAME=${DOMAIN_NAME}" >> .env
                export DOMAIN_NAME
            fi
            ;;
        4)
            if [ -z "$ZONE" ]; then
                read -p "Enter the Zone for the GCE instance (e.g., ${REGION}-a) [${REGION}-a]: " ZONE
                echo "ZONE=${ZONE}" >> .env
                export ZONE
            fi
            : "${ZONE:=${REGION}-a}"
            ;;
    esac
}

# Create terraform.tfvars file for a given scenario
create_tfvars() {
    local scenario_dir=$1
    local scenario_num=$2

    rm -f "${scenario_dir}/terraform.tfvars"

    echo "project_id = \"${PROJECT_ID}\"" > "${scenario_dir}/terraform.tfvars"
    echo "region     = \"${REGION}\"" >> "${scenario_dir}/terraform.tfvars"

    case $scenario_num in
        2)
            echo "zone        = \"${ZONE}\"" >> "${scenario_dir}/terraform.tfvars"
            echo "domain_name = \"${DOMAIN_NAME}\"" >> "${scenario_dir}/terraform.tfvars"
            ;;
        4)
            echo "zone = \"${ZONE}\"" >> "${scenario_dir}/terraform.tfvars"
            ;;
    esac
}

# Run a specific scenario
run_scenario() {
    local scenario_num=$1
    local scenario_dir=$(ls -d diagnostic-scenarios/scenario-${scenario_num}-* | head -n 1)

    if [ -z "$scenario_dir" ] || [ ! -d "$scenario_dir" ]; then
        print_error "Directory for scenario ${scenario_num} not found."
        return
    fi

    local scenario_name=$(basename "$scenario_dir" | sed "s/scenario-${scenario_num}-//" | tr '-' ' ')

    print_info "Starting Scenario ${scenario_num}: ${scenario_name^}"

    get_scenario_vars $scenario_num
    create_tfvars "$scenario_dir" $scenario_num

    cd "$scenario_dir"

    print_info "Running 'terraform init'..."
    terraform init -upgrade >/dev/null

    print_info "Running 'terraform apply'..."
    local apply_log_file=$(mktemp)
    if ! terraform apply -auto-approve 2>&1 | tee "$apply_log_file"; then
        local apply_exit_code=${PIPESTATUS[0]}
    else
        local apply_exit_code=0
    fi

    local apply_output=$(<"$apply_log_file")
    rm "$apply_log_file"

    if [ $apply_exit_code -eq 0 ]; then
        print_success "Terraform apply completed successfully for Scenario ${scenario_num}."

        # Verification
        print_info "Performing verification..."
        case $scenario_num in
            1)
                local url=$(terraform output -raw cloud_run_service_url)
                print_success "Cloud Run service deployed. URL: ${url}"
                ;;
            2)
                local ip=$(terraform output -raw load_balancer_ip)
                print_success "External Load Balancer created. IP: ${ip}"
                print_info "Note: SSL certificate provisioning can take up to an hour."
                print_info "After it's provisioned, you should be able to access your domain via HTTPS."
                ;;
            3)
                local id=$(terraform output -raw connector_id)
                print_success "VPC Connector created. ID: ${id}"
                ;;
            4)
                print_info "Waiting for Cloud NAT to be ready..."
                sleep 60
                print_info "Verifying scenario 4..."
                local cmd="gcloud compute instances get-serial-port-output nat-test-vm --zone=${ZONE} --project=${PROJECT_ID}"
                print_info "Running verification command: ${cmd}"
                if $cmd | grep -q "Hello from Google!"; then
                    print_success "Verified: Private VM has outbound internet access via Cloud NAT."
                else
                    print_error "Verification failed."
                fi
                ;;
            *)
                print_success "Deployment successful (manual verification may be needed)."
                ;;
        esac

        read -p "Do you want to destroy the resources now? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Running 'terraform destroy'..."
            terraform destroy -auto-approve
            print_success "Scenario ${scenario_num} resources destroyed."
        fi
    else
        print_error "Terraform apply failed for Scenario ${scenario_num}."
        echo "--- Terraform Output ---"
        echo "${apply_output}"
        echo "------------------------"
        read -p "Do you want to run the cleanup script (cleanup.sh)? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if [ -f "cleanup.sh" ]; then
                print_info "Running cleanup.sh..."
                bash cleanup.sh
            else
                print_error "cleanup.sh not found in this directory."
            fi
        fi
    fi

    cd ../.. # Return to root
}

# --- UI / Menus ---

# Display the main menu
main_menu() {
    while true; do
        echo
        echo "--- GCP Diagnostic Scenarios ---"
        echo "1. Scenario 1: Cloud Run + GCS"
        echo "2. Scenario 2: GCE + External LB"
        echo "3. Scenario 3: VPC Connector"
        echo "4. Scenario 4: Private GCE + Cloud NAT"
        echo "9. Destroy Resources Menu"
        echo "0. Exit"
        read -p "Select an option: " choice

        case $choice in
            1|2|3|4)
                run_scenario $choice
                ;;
            9)
                destroy_menu
                ;;
            0)
                break
                ;;
            *)
                print_error "Invalid option. Please try again."
                ;;
        esac
    done
}

# Display the destroy menu
destroy_menu() {
     while true; do
        echo
        echo "--- Destroy Resources ---"
        echo "1. Destroy Scenario 1"
        echo "2. Destroy Scenario 2"
        echo "3. Destroy Scenario 3"
        echo "4. Destroy Scenario 4"
        echo "0. Back to Main Menu"
        read -p "Select a scenario to destroy: " choice

        if [[ "$choice" -ge 1 && "$choice" -le 4 ]]; then
            local scenario_dir=$(ls -d diagnostic-scenarios/scenario-${choice}-* | head -n 1)
            if [ -n "$scenario_dir" ] && [ -d "$scenario_dir" ]; then
                print_info "Destroying resources for Scenario ${choice}..."
                cd "$scenario_dir"
                terraform destroy -auto-approve
                cd ../..
                print_success "Destroy operation finished for Scenario ${choice}."
            else
                print_error "Directory for scenario ${choice} not found."
            fi
        elif [ "$choice" -eq 0 ]; then
            break
        else
            print_error "Invalid option."
        fi
    done
}

# --- Main Execution ---
cd "$(dirname "$0")" || exit

check_dependencies
check_gcloud_auth
load_or_create_config
main_menu

print_info
