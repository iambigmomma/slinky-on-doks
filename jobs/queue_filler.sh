#!/bin/bash
#SBATCH --job-name=queue-filler
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=00:15:00
#SBATCH --output=/shared/output/queue_filler-%j.out
#SBATCH --partition=all

echo "=== Queue Filler (Node Hold) ==="
echo "Node: $(hostname)"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Start: $(date)"

echo "Holding node exclusively for 600 seconds..."
echo "This job is designed to test queue backfill and scheduling behavior."

remaining=600
while [ $remaining -gt 0 ]; do
    echo "$(date): ${remaining}s remaining on $(hostname)"
    if [ $remaining -ge 60 ]; then
        sleep 60
        remaining=$((remaining - 60))
    else
        sleep $remaining
        remaining=0
    fi
done

echo "End: $(date)"
echo "=== Queue Filler Complete ==="
