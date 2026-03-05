#!/bin/bash
#SBATCH --job-name=multi-node
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=2
#SBATCH --cpus-per-task=1
#SBATCH --time=00:05:00
#SBATCH --output=/shared/output/multi_node-%j.out
#SBATCH --partition=slinky

echo "=== Multi-Node Distributed Work ==="
echo "Job ID: ${SLURM_JOB_ID}"
echo "Nodes: ${SLURM_JOB_NODELIST}"
echo "Num Nodes: ${SLURM_JOB_NUM_NODES}"
echo "Tasks: ${SLURM_NTASKS}"
echo "Start: $(date)"

srun bash -c '
    echo "Task ${SLURM_PROCID} on $(hostname): starting work"
    end=$((SECONDS + 30))
    count=0
    while [ $SECONDS -lt $end ]; do
        x=0
        for i in $(seq 1 5000); do
            x=$((x + i))
        done
        count=$((count + 1))
    done
    echo "Task ${SLURM_PROCID} on $(hostname): completed ${count} iterations"
'

echo "End: $(date)"
echo "=== Multi-Node Complete ==="
