#!/bin/bash
#SBATCH --job-name=cpu-stress
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --time=00:05:00
#SBATCH --output=/shared/output/cpu_stress-%j.out
#SBATCH --partition=all

echo "=== CPU Stress Test ==="
echo "Node: $(hostname)"
echo "CPUs allocated: ${SLURM_CPUS_PER_TASK}"
echo "Start: $(date)"

if command -v stress-ng &>/dev/null; then
    stress-ng --cpu "${SLURM_CPUS_PER_TASK}" --timeout 120s --metrics-brief
elif command -v python3 &>/dev/null; then
    python3 -c "
import time, os
end = time.time() + 120
count = 0
while time.time() < end:
    x = 0
    for i in range(100000):
        x += i * i
    count += 1
print(f'Completed {count} iterations of CPU work')
"
else
    echo "Falling back to pure bash arithmetic"
    end=$((SECONDS + 120))
    count=0
    while [ $SECONDS -lt $end ]; do
        x=0
        for i in $(seq 1 10000); do
            x=$((x + i * i))
        done
        count=$((count + 1))
    done
    echo "Completed ${count} iterations of CPU work"
fi

echo "End: $(date)"
echo "=== CPU Stress Complete ==="
