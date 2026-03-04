#!/bin/bash
#SBATCH --job-name=hp-sweep
#SBATCH --array=0-9
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00
#SBATCH --output=/shared/output/array_job-%A_%a.out
#SBATCH --partition=all

echo "=== Hyperparameter Sweep ==="
echo "Array Job ID: ${SLURM_ARRAY_JOB_ID}"
echo "Array Task ID: ${SLURM_ARRAY_TASK_ID}"
echo "Node: $(hostname)"
echo "Start: $(date)"

# Simulate hyperparameter sweep with different "learning rates"
LR_VALUES=(0.001 0.005 0.01 0.02 0.05 0.1 0.2 0.5 0.8 1.0)
LR=${LR_VALUES[$SLURM_ARRAY_TASK_ID]}

echo "Testing learning_rate=${LR}"

# Simulate training with bash arithmetic
iterations=50
best_loss=1000
for i in $(seq 1 $iterations); do
    # Pseudo-random loss decrease
    loss=$((1000 - i * (SLURM_ARRAY_TASK_ID + 1)))
    if [ $loss -lt $best_loss ]; then
        best_loss=$loss
    fi
done

echo "Result: learning_rate=${LR}, best_loss=${best_loss}, iterations=${iterations}"
echo "End: $(date)"
echo "=== Sweep Task ${SLURM_ARRAY_TASK_ID} Complete ==="
