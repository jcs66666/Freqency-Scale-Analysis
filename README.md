# CPU Freqency-Scale-Analysis

Socket CPU Frequency Test

run-frequency.sh automatically detects the online physical cores and their SMT sibling threads on the specified socket, without hard-coding the core count or CPU IDs.

By default, the script first starts one load thread per physical core, then gradually adds the SMT sibling threads. Each load thread is independently pinned to a CPU, and only CPUs on the selected socket are used.

The output graph contains a single average-frequency curve. The X-axis represents the number of fully loaded logical CPUs / threads. Therefore, once SMT threads are added, the number of active physical cores no longer increases.

Usage
cd /home/Freqency-Scale-Analysis

# Display the topology, CPU order, and test points for Socket 0 without starting the workload
DRY_RUN=1 ./run-frequency.sh 0

# Test Socket 0: physical cores + SMT
sudo ./run-frequency.sh 0

# Test physical cores only, increasing the load by 4 cores at each step
sudo env SMT=0 STEP=4 ./run-frequency.sh 0

# Test Socket 1
sudo ./run-frequency.sh 1

# Use custom test points and sampling settings
# The number of test points must not exceed the number of online CPUs on the selected socket
sudo env POINTS=1,24,48,72,96 WARMUP=20 SAMPLES=20 INTERVAL=1 ./run-frequency.sh 0


Dependencies: Bash, lscpu, stress-ng, turbostat, taskset, awk, and standard Linux utilities.

Both the test and SVG plotting are implemented in a single shell script. Python, matplotlib, and gnuplot are not required.

Parameters
Parameter	Default	DescriptionPositional argument	0	Socket ID
SMT	1	1: physical cores + SMT; 0: select only one thread per physical core
STEP	8	Default interval between test points. The script also includes 1, 2, 4, the physical core count, and the maximum thread count
POINTS	Empty	Custom comma-separated test points. Overrides the default test points when specified
WARMUP	20	Warm-up time in seconds for each test point
SAMPLES	20	Number of frequency samples collected at each test point
INTERVAL	1	Sampling interval in seconds
DRY_RUN	0	1: display the topology and test points only
Results and Statistical Method

Each run creates a directory in the following format:

results-CPU_MODEL-socket<ID>-YYYYMMDD_HHMMSS/


For example:

results-AMD_EPYC_9455_48-Core_Processor-socket0-20261108_153000/


Spaces and special characters in the CPU model name are converted to underscores. The timestamp uses the server's current time. If a directory with the same name already exists, the script stops to avoid overwriting previous results.

The output directory contains:

frequency.svg: Average core frequency versus the number of fully loaded threads. It can be opened directly in a web browser.
summary.csv: Number of loaded threads, actual number of physical cores used, average frequency in GHz, and average utilization.
topology.csv, settings.txt: CPU topology and test settings for the current run.
raw-*.tsv, affinity-*.csv, load-*.log: Raw frequency data, workload process CPU affinity records, and workload logs.
original-governors.tsv: CPU frequency governor settings recorded before the test.

The workload is fixed to stress-ng matrixprod.

Frequency is measured using turbostat Bzy_MHz. Samples are first averaged across active threads belonging to the same physical core and across the sampling interval. The resulting per-core values are then averaged with equal weighting across all active physical cores.

Each active thread must maintain at least 90% utilization during sampling. If this requirement is not met, the test stops.

The script sets only the cpufreq policies associated with the selected socket to performance. It does not modify Boost settings, SMT configuration, or the hardware maximum frequency.

When the test completes normally, encounters an error, or receives Ctrl+C, the current workload is stopped and the original frequency governor settings are restored.

In the event of SIGKILL or a power failure, the cleanup routine cannot run. In such cases, the original governor settings can be restored manually using the saved original-governors.tsv.

This test is intended as a short-duration CPU frequency scaling test under a fixed matrix workload. For formal comparisons, use identical warm-up and sampling settings across systems, and increase the test duration and number of repeated runs as needed.
