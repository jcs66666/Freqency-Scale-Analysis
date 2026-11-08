#!/usr/bin/env bash
# 功能：测试指定 Socket 的平均核心频率，输出原始数据、CSV 和单条 SVG 曲线。
# 用法：sudo ./run-frequency.sh [Socket编号]，未提供编号时默认使用 Socket 0。
# 示例：sudo env SMT=0 STEP=4 ./run-frequency.sh 0
#       DRY_RUN=1 ./run-frequency.sh 0
#
# 环境变量：
#   STEP=8       默认测试点的线程数间隔，另补充 1、2、4 和物理核/总线程边界。
#   WARMUP=20    每档预热秒数，预热结束后才开始采样。
#   SAMPLES=20   每档采样次数。
#   INTERVAL=1   每次采样间隔，单位为秒。
#   SMT=1        1：先每物理核一个线程，再加入兄弟线程；0：只用每核一个线程。
#   POINTS=...   自定义测试点，如 1,24,48,96；设置后覆盖默认测试点。
#   DRY_RUN=1    仅显示 CPU 顺序和测试点，不创建目录、不改设置、不启动负载。
#
# Linux 的 CPU 编号表示逻辑线程，不等同于物理核编号。
# SMT 阶段继续增加的是活动线程数，实际使用的物理核数量保持不变。
# 测试与绘图均在本脚本内完成，不依赖 Python 或额外绘图库。

# 严格模式：命令失败、引用未定义变量或管道中某一步失败时退出。
set -Eeuo pipefail

# ---------- 1. 参数读取与校验 ----------
# ${变量:-默认值} 表示外部未提供变量时使用默认值。
socket=${1:-0}
STEP=${STEP:-8}; WARMUP=${WARMUP:-5}; SAMPLES=${SAMPLES:-20}
INTERVAL=${INTERVAL:-1}; SMT=${SMT:-1}; DRY_RUN=${DRY_RUN:-0}
# Socket 编号和预热时间允许为 0；步长、次数和采样间隔必须大于 0。
for value in "$socket" "$WARMUP" "$SMT" "$DRY_RUN"; do
    [[ $value =~ ^[0-9]+$ ]] || { echo 'Options must be integers.' >&2; exit 1; }
done
for value in "$STEP" "$SAMPLES" "$INTERVAL"; do
    [[ $value =~ ^[1-9][0-9]*$ ]] || { echo 'STEP, SAMPLES and INTERVAL must be positive integers.' >&2; exit 1; }
done
[[ $SMT == 0 || $SMT == 1 ]] || { echo 'SMT must be 0 or 1.' >&2; exit 1; }

# ---------- 2. 自动识别目标 Socket 的在线 CPU 拓扑 ----------
# lscpu 四列依次为：逻辑 CPU 编号、物理核编号、Socket 编号、是否在线。
# 去掉注释、其他 Socket 和离线线程，得到“CPU编号,物理核编号”。
# 按物理核和 CPU 编号排序，不假设机器的核心数量或 CPU 编号连续。
topology=$(lscpu -p=CPU,CORE,SOCKET,ONLINE |
    awk -F, -v socket="$socket" '$1 !~ /^#/ && $3 == socket && $4 == "Y" {print $1 "," $2}' |
    sort -t, -k2,2n -k1,1n)
[[ -n $topology ]] || { echo "Socket $socket has no online CPUs." >&2; exit 1; }
# 物理核编号去重后，得到目标 Socket 实际在线的物理核数量。
physical=$(awk -F, '{cores[$2]=1} END {print length(cores)}' <<< "$topology")
# 同一物理核的线程依次标记 rank=1、2……，再优先按 rank 排序。
# 因此先选完每核的第一个线程，再加入每核的第二个线程（SMT 兄弟线程）。
# SMT=0 时只保留 rank=1；mapfile 把最终 CPU 顺序保存为 Bash 数组。
mapfile -t cpus < <(awk -F, -v smt="$SMT" '{rank=++seen[$2]; if (smt || rank==1) print rank "," $2 "," $1}' <<< "$topology" |
    sort -t, -k1,1n -k2,2n | cut -d, -f3)
total=${#cpus[@]}

# ---------- 3. 生成测试点 ----------
# 一个测试点 n 表示给 cpus 数组的前 n 个 CPU 分别启动一个负载线程。
# 自定义 POINTS 时先排序和去重；否则按 STEP 生成并补齐关键边界点。
if [[ -n ${POINTS:-} ]]; then
    [[ $POINTS =~ ^[0-9]+(,[0-9]+)*$ ]] || { echo 'POINTS must be comma-separated integers.' >&2; exit 1; }
    mapfile -t points < <(tr ',' '\n' <<< "$POINTS" | sort -nu)
else
    mapfile -t points < <({
        for n in 1 2 4; do ((n <= total)) && echo "$n"; done
        seq "$STEP" "$STEP" "$total"; echo "$physical"; echo "$total"
    } | sort -nu)
fi
# 检查所有测试点是否落在可用 CPU 数量范围内。
for n in "${points[@]}"; do
    ((n >= 1 && n <= total)) || { echo "Test point $n is outside 1-$total." >&2; exit 1; }
done
echo "Socket $socket: $physical physical cores, $(wc -l <<< "$topology") online CPU threads."
echo "Selected CPU order: ${cpus[*]}"
echo "Test points: ${points[*]} (SMT=$SMT)"
# Dry-run 在权限检查之前退出，普通用户也可以查看拓扑和负载安排。
[[ $DRY_RUN == 1 ]] && exit 0
((EUID == 0)) || { echo 'Run with sudo/root; turbostat requires privileged counter access.' >&2; exit 1; }
for tool in stress-ng turbostat taskset; do command -v "$tool" >/dev/null; done

# ---------- 4. 建立独立结果目录 ----------
# 始终将结果保存在脚本所在目录，不受启动时工作目录的影响。
base=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# 固定英文区域设置，以匹配 Model name 字段；型号中的特殊字符改为下划线。
cpu_model=$(LC_ALL=C lscpu | sed -n 's/^Model name:[[:space:]]*//p' |
    sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+|_+$//g')
# 使用服务器当前时间，格式为“年月日_时分秒”。
run_time=$(date +%Y%m%d_%H%M%S)
out="$base/results-${cpu_model:-UnknownCPU}-socket${socket}-${run_time}"
# 不使用 mkdir -p：若同名目录已存在则停止，避免覆盖已有结果。
mkdir -- "$out"
# 保存拓扑和测试设置，便于事后核查 CPU 分配和复现本次测试。
printf '%s\n' "$topology" > "$out/topology.csv"
printf 'socket=%s\nSMT=%s\nWARMUP=%s\nSAMPLES=%s\nINTERVAL=%s\nCPU_ORDER=%s\n' \
    "$socket" "$SMT" "$WARMUP" "$SAMPLES" "$INTERVAL" "${cpus[*]}" > "$out/settings.txt"
echo 'active_threads,active_physical_cores,mean_GHz,mean_busy_pct' > "$out/summary.csv"

# pids 只记录本次启动的 stress-ng 主进程，清理时不会按名称结束其他任务。
pids=()
# 关联数组：键为 cpufreq 策略文件真实路径，值为测试前的调频策略。
declare -A governors=()
# 先通知本次负载结束，再等待退出，避免上一档负载影响下一档。
# stress-ng 主进程接收 TERM 后负责停止其工作进程。
stop_load() {
    for pid in "${pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
    pids=()
}
# 正常结束或异常退出时统一停止负载并恢复原 governor。
# SIGKILL、断电等无法触发 Shell 清理，原设置也保存在结果目录中供恢复。
cleanup() {
    stop_load
    for path in "${!governors[@]}"; do printf '%s' "${governors[$path]}" > "$path"; done
}
# INT（通常是 Ctrl+C）和 TERM 转换为退出，再由 EXIT 统一清理。
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# ---------- 5. 保存并修改所选 Socket 的调频策略 ----------
# 多个 CPU 可能共享一个 cpufreq policy，用真实路径作为关联数组键去重。
# 必须先读取全部原设置再修改，避免把已经改成 performance 的值记为原值。
for cpu in "${cpus[@]}"; do
    path=$(readlink -f "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor")
    [[ -f $path ]] && governors[$path]=$(cat "$path")
done
# 只修改所选 CPU 对应的策略；不改变 Boost、SMT 开关或硬件最高频率。
for path in "${!governors[@]}"; do
    printf '%s\t%s\n' "$path" "${governors[$path]}" >> "$out/original-governors.tsv"
    echo performance > "$path"
done

# ---------- 6. 逐档启动负载、预热与采样 ----------
for n in "${points[@]}"; do
    # 数组切片取前 n 个 CPU，保持“先物理核，再 SMT”的顺序。
    selected=("${cpus[@]:0:n}")
    echo "Testing $n threads: ${selected[*]}"
    # 超时比预热加采样时间多留 30 秒余量；正常采样结束后会主动停止负载。
    timeout=$((WARMUP + SAMPLES * INTERVAL + 30))
    # 每个 CPU 独立启动一个固定 matrixprod 负载；taskset 设置单 CPU 亲和性。
    # 工作子进程继承这个限制；$! 保存后台主进程 PID，与 selected 一一对应。
    for cpu in "${selected[@]}"; do
        taskset -c "$cpu" stress-ng --cpu 1 --cpu-method matrixprod --timeout "${timeout}s" \
            > "$out/load-${n}-cpu${cpu}.log" 2>&1 &
        pids+=("$!")
    done
    # 预热不计入频率样本，减少刚启动时的瞬态影响。
    sleep "$WARMUP"
    # 用 /proc 检查负载主进程实际允许使用的 CPU，并保存 PID/CPU 对应记录。
    # 进程已退出或绑核不匹配时，严格模式会终止脚本并触发清理。
    for index in "${!pids[@]}"; do
        pid=${pids[$index]}; cpu=${selected[$index]}
        [[ $(awk '/Cpus_allowed_list:/ {print $2}' "/proc/$pid/status") == "$cpu" ]]
        printf '%s,%s\n' "$pid" "$cpu" >> "$out/affinity-$n.csv"
    done
    # Busy%：采样区间内忙碌比例；Bzy_MHz：忙碌期间的实际平均频率。
    # turbostat 采样整机，汇总时只取 selected CPU。
    # 标准输入使用 /dev/null，避免在后台或 SSH 环境中等待交互输入。
    turbostat --quiet --show CPU,Busy%,Bzy_MHz --interval "$INTERVAL" \
        --num_iterations "$SAMPLES" --out "$out/raw-$n.tsv" < /dev/null
    # kill -0 只检查进程是否仍然存在，不发出终止信号；确保负载覆盖采样期。
    for pid in "${pids[@]}"; do kill -0 "$pid"; done
    stop_load

    # ---------- 7. 校验与统计本档数据 ----------
    # 要求样本数等于“活动线程数 × 采样次数”，且每条活动线程样本利用率 >=90%。
    # 平均频率分两步：
    #   ① 对同一物理核的活动线程和全部采样区间取平均；
    #   ② 各物理核再等权平均，MHz 除以 1000 转为 GHz。
    # 避免部分核心启用两个 SMT 线程时，在整体统计中获得双倍权重。
    awk -F '[,\t ]+' -v selected="${selected[*]}" -v n="$n" -v samples="$SAMPLES" '
        # active 保存本档选中的逻辑 CPU 集合。
        BEGIN {split(selected, ids, " "); for (i in ids) active[ids[i]]=1}
        # NR==FNR 表示当前在读第一个文件，即 CPU -> 物理核映射表。
        NR==FNR {core[$1]=$2; next}
        # 第二个文件的三列依次为 CPU、Busy%、Bzy_MHz。
        $1 in active {
            count++; busy+=$2; if ($2<90) bad=1;
            sum[core[$1]]+=$3; hits[core[$1]]++
        }
        END {
            if (count!=n*samples || bad) {print "Invalid samples or CPU utilization below 90%." > "/dev/stderr"; exit 1}
            # sum/hits 得到每核均值，cores 是本档真正参与的物理核数量。
            for (c in sum) {freq+=sum[c]/hits[c]; cores++}
            printf "%d,%d,%.6f,%.2f\n", n,cores,freq/cores/1000,busy/count
        }' "$out/topology.csv" "$out/raw-$n.tsv" | tee -a "$out/summary.csv"
    # 档位间短暂空闲，并不意味着达到热平衡。
    sleep 3
done

# ---------- 8. 直接使用 awk 输出单条频率曲线 SVG ----------
# SVG 是浏览器可直接打开的矢量图，无需额外绘图库。
# 横轴为满载逻辑线程数；SMT=0 时它也等于满载物理核数。
# 画布为 1040×580，数据区域为 x=90..940、y=100..450。
awk -F, -v socket="$socket" -v warmup="$WARMUP" -v samples="$SAMPLES" -v interval="$INTERVAL" '
    # 将实际线程数/GHz 映射为画布坐标；SVG 的 y 向下增加，所以高频率在上方。
    # 只有一个测试点时横轴分母至少取 1，避免除零。
    function px(value) {return 90+(value-1)/(xmax>1 ? xmax-1 : 1)*850}
    function py(value) {return 450-(value-ymin)/(ymax-ymin)*350}
    # 跳过 CSV 表头，读取线程数与频率，确定纵轴上下界。
    NR==1 {next}
    {
        n++; x[n]=$1; y[n]=$3
        if (n==1 || $3<ymin) ymin=$3
        if (n==1 || $3>ymax) ymax=$3
        xmax=$1
    }
    END {
        # 上下留白；所有频率相同时仍保证纵轴范围大于零。
        padding=(ymax-ymin)*.15; if (padding<.025) padding=.025
        ymin-=padding; ymax+=padding
        print "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1040\" height=\"580\" viewBox=\"0 0 1040 580\">"
        print "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>"
        print "<g font-family=\"sans-serif\" font-size=\"14\" fill=\"#333\">"
        printf "<text x=\"520\" y=\"35\" text-anchor=\"middle\" font-size=\"22\">Socket %s: average core frequency</text>\n",socket
        # 绘制 6 条水平网格线和对应的 GHz 刻度。
        for (i=0;i<=5;i++) {
            value=ymin+(ymax-ymin)*i/5; pos=py(value)
            printf "<path d=\"M90 %.2fH940\" stroke=\"#e5e7eb\"/>\n",pos
            printf "<text x=\"80\" y=\"%.2f\" text-anchor=\"end\">%.3f</text>\n",pos+5,value
        }
        print "<path d=\"M90 100V450H940\" fill=\"none\" stroke=\"#555\"/>"
        print "<text x=\"520\" y=\"520\" text-anchor=\"middle\">Active CPU threads (physical cores first, then SMT siblings)</text>"
        print "<text transform=\"translate(24 275) rotate(-90)\" text-anchor=\"middle\">Mean core frequency (GHz)</text>"
        # 所有点连接成唯一一条平均核心频率曲线。
        printf "<polyline fill=\"none\" stroke=\"#1766aa\" stroke-width=\"3\" points=\""
        for (i=1;i<=n;i++) printf "%.2f,%.2f ",px(x[i]),py(y[i])
        print "\"/>"
        # 每点绘制圆点及悬停提示；点数较多时稀疏显示横轴标签，避免重叠。
        stride=int((n+15)/16)
        for (i=1;i<=n;i++) {
            printf "<circle cx=\"%.2f\" cy=\"%.2f\" r=\"4\" fill=\"#1766aa\"><title>%d threads: %.6f GHz</title></circle>\n",px(x[i]),py(y[i]),x[i],y[i]
            if ((i-1)%stride==0 || i==n)
                printf "<text x=\"%.2f\" y=\"475\" text-anchor=\"middle\">%d</text>\n",px(x[i]),x[i]
        }
        printf "<text x=\"520\" y=\"555\" text-anchor=\"middle\" font-size=\"12\">stress-ng matrixprod | warmup %ss | %s samples x %ss | turbostat Bzy_MHz</text>\n",warmup,samples,interval
        print "</g></svg>"
    }' "$out/summary.csv" > "$out/frequency.svg"
# 打印结果位置；脚本退出时 EXIT trap 自动恢复原 governor。
echo "Results: $out"
