#!/bin/bash

# Path to your runAJob.sh script (update this if needed)
RUN_A_JOB="/path/to/runAJob.sh"

# Path to the job list file (hardcoded)
JOB_LIST_FILE="jobs.txt"

# Define some colors for UI
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
CYAN="\033[36m"
RESET="\033[0m"
BOLD="\033[1m"

# Temp file for results (shared across subshells)
RESULTS_FILE=$(mktemp)

# Function to display credits and usage
show_credits_and_usage() {
    clear
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${CYAN}${BOLD}        Welcome to the Job Runner Application        "
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${RESET}This tool helps you to run and manage tasks."
    echo -e "You can run jobs sequentially or concurrently with simple commands."
    echo -e ""
    echo -e "${BOLD}Credits:${RESET} Developed by ${CYAN}${BOLD}Uday Kiran Pamu.${RESET}"
    echo -e "${BOLD}Usage:${RESET} Provide the Job Number to execute specifically or leave blank for all when prompted."
    echo -e "${BOLD}Usage:${RESET} Choose execution mode (sequential or parallel) when prompted."
    echo -e "${RED}${BOLD}Note:${RESET} ${RED}${BOLD}Be Cautious While executing Parallel Mode as it will run all the Jobs at once."
    echo -e ""
    echo -e "${YELLOW}Press [Enter] to continue...${RESET}"
    read -r
}

# Function to show elapsed time while a job runs
show_timer() {
    local pid=$1
    local start=$(date +%s)
    while kill -0 $pid 2>/dev/null; do
        local now=$(date +%s)
        local elapsed=$((now - start))
        printf "Running... %ds elapsed\r" "$elapsed"
        sleep 1
    done
    echo ""
}

# Function to execute the job and handle the output
execute_job() {
    local job="$1"
    local mode="$2"
    echo -e "Executing: $RUN_A_JOB $job"

    # Run the job in background
    $RUN_A_JOB $job 2>&1 &
    pid=$!

    # Show elapsed time while job runs
    show_timer $pid

    # Wait for job to finish and capture return code
    wait $pid
    rc=$?

    if [ $rc -eq 0 ]; then
        echo -e "${GREEN}Job $job succeeded.${RESET}"
        echo "SUCCESS:$job" >> "$RESULTS_FILE"
    else
        echo -e "${RED}Job $job failed with return code $rc.${RESET}"
        echo "FAIL:$job" >> "$RESULTS_FILE"

        # Retry loop only in sequential mode
        if [[ "$mode" == "sequential" ]]; then
            while true; do
                echo -e "${YELLOW}What would you like to do? (r)erun, (s)kip, or (e)xit? (r/s/e): ${RESET}"
                read -r choice
                case $choice in
                    [Rr]*)
                        echo "Rerunning job $job..."
                        $RUN_A_JOB $job 2>&1 &
                        pid=$!
                        show_timer $pid
                        wait $pid
                        rc=$?
                        if [ $rc -eq 0 ]; then
                            echo -e "${GREEN}Job $job succeeded on rerun.${RESET}"
                            echo "SUCCESS:$job (rerun)" >> "$RESULTS_FILE"
                            break
                        else
                            echo -e "${RED}Job $job failed again with return code $rc.${RESET}"
                        fi
                        ;;
                    [Ss]*)
                        echo "Skipping job $job."
                        break
                        ;;
                    [Ee]*)
                        echo "Exiting script."
                        exit 0
                        ;;
                esac
            done
        fi
    fi
    echo -e "--------------------------------------------"
}

# Function to load jobs from the hardcoded job list file
load_jobs_from_file() {
    if [[ ! -f "$JOB_LIST_FILE" ]]; then
        echo -e "${RED}Job list file '$JOB_LIST_FILE' not found! Please provide a valid file.${RESET}"
        exit 1
    fi
    mapfile -t jobs < "$JOB_LIST_FILE"
}

# Function to show the list of jobs in a table format
show_job_list() {
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${CYAN}${BOLD}        Available Jobs List:                     "
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${RESET}ID | Job Name"
    echo -e "-------------------------------------------------"
    for i in "${!jobs[@]}"; do
        echo -e "$((i+1))  | ${jobs[$i]}"
    done
    echo -e "-------------------------------------------------"
}

# Function to load the user-selected jobs based on input
select_jobs() {
    echo -e "${YELLOW}Enter the job numbers to execute (comma-separated, e.g. 1,2,4). Leave blank for all: ${RESET}"
    read -r selected_jobs_input

    if [[ -z "$selected_jobs_input" ]]; then
        selected_jobs=($(seq 1 ${#jobs[@]}))
    else
        selected_jobs=($(echo "$selected_jobs_input" | tr "," "\n"))
    fi
}

# Ask the user to choose execution mode: sequential or parallel
show_execution_menu() {
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${CYAN}${BOLD}         Job Runner - Select Execution Mode        "
    echo -e "${CYAN}${BOLD}-------------------------------------------------"
    echo -e "${RESET}Please choose how you'd like to run your jobs:"
    echo -e "1. Sequential Execution (one job at a time)"
    echo -e "2. Parallel Execution (run jobs concurrently)"
    echo -e ""
    echo -e "${YELLOW}Enter your choice (1 or 2): ${RESET}"
    read -r choice

    case $choice in
        1)
            echo -e "${YELLOW}Starting jobs sequentially...${RESET}"
            for job_number in "${selected_jobs[@]}"; do
                execute_job "${jobs[$((job_number - 1))]}" "sequential"
            done
            ;;
        2)
            echo -e "${YELLOW}Starting jobs in parallel...${RESET}"
            for job_number in "${selected_jobs[@]}"; do
                execute_job "${jobs[$((job_number - 1))]}" "parallel" &
            done
            wait
            ;;
        *)
            echo -e "${RED}Invalid choice. Please enter 1 or 2.${RESET}"
            show_execution_menu
            ;;
    esac
}

# Function to show summary report
show_summary() {
    echo -e "${CYAN}${BOLD}================= SUMMARY REPORT =================${RESET}"
    echo -e "${GREEN}Succeeded Jobs:${RESET}"
    grep "^SUCCESS:" "$RESULTS_FILE" | cut -d: -f2- || echo "  None"

    echo -e "${RED}Failed Jobs:${RESET}"
    grep "^FAIL:" "$RESULTS_FILE" | cut -d: -f2- || echo "  None"

    echo -e "${CYAN}${BOLD}==================================================${RESET}"
    rm -f "$RESULTS_FILE"
}

# Main function to start the application
main() {
    load_jobs_from_file
    show_credits_and_usage
    show_job_list
    select_jobs
    show_execution_menu
    show_summary
    echo -e "${GREEN}All jobs completed!${RESET}"
}

main
