#!/bin/bash

# 脚本配置
SCRIPT_NAME=$(basename "$0")
VERSION="1.0"
CPU_THRESHOLD=100  # CPU使用率阈值，超过此值启动perf监控

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

# 显示帮助信息
show_help() {
    cat << EOF
用法: $SCRIPT_NAME <PID> <监听时长(秒)> [选项]

选项:
    --perf          强制启用perf监控
    --threshold N   设置CPU使用率阈值 (默认: $CPU_THRESHOLD%)
    --help          显示此帮助信息

示例:
    $SCRIPT_NAME 1234 10                    # 基本监控
    $SCRIPT_NAME 1234 -1                    # 持续监控直到Ctrl+C停止
    $SCRIPT_NAME 1234 10 --perf            # 强制启用perf监控
    $SCRIPT_NAME 1234 10 --threshold 80    # 设置阈值为80%

功能:
    - 实时监控指定进程的CPU和内存使用率
    - 当CPU使用率超过阈值时自动启动perf性能分析
    - 支持持续监控模式（时长设为-1）
    - 生成详细的统计报告和火焰图
EOF
}

# 参数解析
parse_arguments() {
    if [ $# -lt 2 ]; then
        show_help
        exit 1
    fi

    PID=$1
    DURATION=$2
    ENABLE_PERF=false
    AUTO_PERF=true

    # 检查是否为持续监听模式
    if [ "$DURATION" = "-1" ]; then
        CONTINUOUS_MODE=true
        DURATION=999999  # 设置一个很大的数值用于显示
    else
        CONTINUOUS_MODE=false
    fi

    shift 2
    while [[ $# -gt 0 ]]; do
        case $1 in
            --perf | -p)
                ENABLE_PERF=true
                AUTO_PERF=false
                shift
                ;;
            --threshold | -t)
                CPU_THRESHOLD=$2
                shift 2
                ;;
            --help)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 权限检查
check_permissions() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请以root用户身份运行此脚本"
        exit 1
    fi
}

# 检查PID是否存在
check_pid() {
    if ! kill -0 $PID 2>/dev/null; then
        log_error "PID $PID 不存在或无法访问"
        exit 1
    fi
}

# 配置系统参数
configure_system() {
    if ! grep -q "kernel.perf_event_paranoid = -1" /etc/sysctl.conf; then
        log_info "配置perf权限..."
        echo "" | sudo tee -a /etc/sysctl.conf
        echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
        sysctl -p
    fi
}

# 获取进程名称
get_process_name() {
    local pid=$1
    local process_name=""
    
    # 尝试从/proc获取进程名称
    if [ -f "/proc/$pid/comm" ]; then
        process_name=$(cat "/proc/$pid/comm" 2>/dev/null | tr -d '\n')
    fi
    
    # 如果获取失败，尝试从ps命令获取
    if [ -z "$process_name" ]; then
        process_name=$(ps -p $pid -o comm= 2>/dev/null | head -1 | tr -d '\n')
    fi
    
    # 如果还是获取失败，使用默认值
    if [ -z "$process_name" ]; then
        process_name="unknown"
    fi
    
    echo "$process_name"
}

# 创建输出目录
create_output_dir() {
    PROCESS_NAME=$(get_process_name $PID)
    OUTPUT_DIR="record_output_${PROCESS_NAME}_PID${PID}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p $OUTPUT_DIR
    log_info "创建输出目录: $OUTPUT_DIR"
}

# 设置环境变量
setup_environment() {
    export LD_LIBRARY_PATH=$(pwd)/lib:$LD_LIBRARY_PATH
}

# 进度显示函数
show_progress() {
    local duration=$1
    local elapsed=0
    local interval=1
    
    if [ "$CONTINUOUS_MODE" = true ]; then
        log_info "持续监控模式 - 按Ctrl+C停止"
        while true; do
            printf "\r[持续监控] 已监控: %ds" $elapsed
            sleep $interval
            elapsed=$((elapsed + interval))
        done
    else
        log_info "监控进度:"
        while [ $elapsed -lt $duration ]; do
            local percentage=$((elapsed * 100 / duration))
            local remaining=$((duration - elapsed))
            printf "\r[%3d%%] 已监控: %ds, 剩余: %ds" $percentage $elapsed $remaining
            sleep $interval
            elapsed=$((elapsed + interval))
        done
        printf "\r[100%%] 监控完成! 总时长: %ds\n" $duration
    fi
    echo ""  # 添加空行，避免与后续输出混在一起
}

# 信号处理函数
cleanup_on_exit() {
    log_info "收到停止信号，正在清理..."
    
    # 停止所有后台进程
    if [ -n "$top_pid" ] && kill -0 $top_pid 2>/dev/null; then
        kill $top_pid 2>/dev/null
    fi
    if [ -n "$progress_pid" ] && kill -0 $progress_pid 2>/dev/null; then
        kill $progress_pid 2>/dev/null
    fi
    if [ -n "$perf_pid" ] && kill -0 $perf_pid 2>/dev/null; then
        kill $perf_pid 2>/dev/null
    fi
    
    # 等待进程结束
    wait 2>/dev/null
    
    # 如果启动了perf，等待其完成并生成火焰图
    if [ -n "$perf_pid" ] && [ -f "$OUTPUT_DIR/perf_env.data" ]; then
        log_info "等待perf监控完成..."
        wait $perf_pid 2>/dev/null
        
        log_info "正在生成火焰图..."
        ./bin/perf script -i $OUTPUT_DIR/perf_env.data > $OUTPUT_DIR/perf_env.unfold
        ./FlameGraph/stackcollapse-perf.pl $OUTPUT_DIR/perf_env.unfold > $OUTPUT_DIR/perf_env.folded
        ./FlameGraph/flamegraph.pl $OUTPUT_DIR/perf_env.folded > $OUTPUT_DIR/perf_PID${PID}_${PROCESS_NAME}_$(date +%Y%m%d_%H%M%S).svg
        log_info "perf监控完成，火焰图已生成"
    fi
    
    # 移动top输出到最终位置
    if [ -f "$temp_file" ]; then
        mv $temp_file $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt
    fi
    
    # 处理数据并生成报告
    process_top_data
    generate_cpu_mem_report
    cleanup
    package_summary
    
    exit 0
}

# 实时监控CPU使用率并决定是否启动perf
monitor_and_perf() {
    temp_file=$(mktemp)
    perf_started=false
    perf_pid=""
    
    # 设置信号处理
    trap cleanup_on_exit INT TERM
    
    if [ "$CONTINUOUS_MODE" = true ]; then
        log_info "开始持续监控 PID: $PID (${PROCESS_NAME}) (按Ctrl+C停止)"
    else
        log_info "开始实时监控 PID: $PID (${PROCESS_NAME}), 时长: ${DURATION}秒"
    fi
    log_info "CPU阈值: ${CPU_THRESHOLD}% (超过此值将自动启动perf监控)"
    
    # 启动top监控到临时文件
    if [ "$CONTINUOUS_MODE" = true ]; then
        # 持续监控模式：使用无限循环
        top -p $PID -b -d 1 > $temp_file &
        top_pid=$!
    else
        # 定时监控模式
        top -p $PID -b -d 1 -n $DURATION > $temp_file &
        top_pid=$!
    fi
    
    # 启动进度显示
    show_progress $DURATION &
    progress_pid=$!
    
    # 实时监控top输出
    while kill -0 $top_pid 2>/dev/null; do
        # 检查最新的CPU使用率
        local latest_cpu=$(tail -n 1 $temp_file | awk -v pid="$PID" '
            $1 == pid {
                cpu_usage = $9
                if (cpu_usage ~ /^[0-9]+\.?[0-9]*$/) {
                    print cpu_usage
                    exit
                }
            }
        ')
        
        if [ -n "$latest_cpu" ] && [ "$latest_cpu" != "0.0" ]; then
            # 检查是否超过阈值且perf未启动
            if [ "$AUTO_PERF" = true ] && [ "$perf_started" = false ]; then
                # 使用awk进行浮点数比较，避免依赖bc命令
                cpu_check=$(awk -v cpu="$latest_cpu" -v threshold="$CPU_THRESHOLD" 'BEGIN {
                    if (cpu > threshold) print "1"
                    else print "0"
                }')
                
                if [ "$cpu_check" = "1" ]; then
                    echo ""
                    log_info "CPU使用率 ${latest_cpu}% 超过阈值 ${CPU_THRESHOLD}%，启动perf监控..."
                    ./bin/perf record -e cpu-cycles --call-graph fp -p $PID -o $OUTPUT_DIR/perf_env.data sleep 10 > /dev/null 2>&1
                    ./bin/perf script -i $OUTPUT_DIR/perf_env.data > $OUTPUT_DIR/perf_env.unfold
                    ./FlameGraph/stackcollapse-perf.pl $OUTPUT_DIR/perf_env.unfold > $OUTPUT_DIR/perf_env.folded
                    ./FlameGraph/flamegraph.pl $OUTPUT_DIR/perf_env.folded > $OUTPUT_DIR/perf_PID${PID}_${PROCESS_NAME}_$(date +%Y%m%d_%H%M%S)_CPU${latest_cpu}.svg
                    echo ""
                    log_info "perf监控完成，火焰图已生成: $OUTPUT_DIR/perf_PID${PID}_${PROCESS_NAME}_$(date +%Y%m%d_%H%M%S)_CPU${latest_cpu}.svg"
                fi
            fi
        fi
        
    done
    
    # 等待所有后台进程完成
    wait $top_pid
    wait $progress_pid
    
    # 移动top输出到最终位置
    mv $temp_file $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt
}

# 强制perf监控
force_perf_monitoring() {
    log_info "强制启用perf监控..."
    
    # 设置信号处理
    trap cleanup_on_exit INT TERM
    
    # 创建临时文件用于top输出
    temp_file=$(mktemp)
    
    # 启动top监控到临时文件
    if [ "$CONTINUOUS_MODE" = true ]; then
        # 持续监控模式：使用无限循环
        top -p $PID -b -d 1 > $temp_file &
        top_pid=$!
    else
        # 定时监控模式
        top -p $PID -b -d 1 -n $DURATION > $temp_file &
        top_pid=$!
    fi
    
    # 启动进度显示
    show_progress $DURATION &
    progress_pid=$!
    
    # 启动perf监控
    if [ "$CONTINUOUS_MODE" = true ]; then
        # 持续监控模式：使用一个很长的持续时间
        ./bin/perf record -e cpu-cycles --call-graph fp -p $PID -o $OUTPUT_DIR/perf_env.data sleep 10 &
        perf_pid=$!
    else
        # 定时监控模式
        ./bin/perf record -e cpu-cycles --call-graph fp -p $PID -o $OUTPUT_DIR/perf_env.data sleep $DURATION &
        perf_pid=$!
    fi
    
    # 等待所有后台进程完成
    wait $top_pid
    wait $progress_pid
    wait $perf_pid
    
    log_info "正在生成火焰图..."
    ./bin/perf script -i $OUTPUT_DIR/perf_env.data > $OUTPUT_DIR/perf_env.unfold
    ./FlameGraph/stackcollapse-perf.pl $OUTPUT_DIR/perf_env.unfold > $OUTPUT_DIR/perf_env.folded
    ./FlameGraph/flamegraph.pl $OUTPUT_DIR/perf_env.folded > $OUTPUT_DIR/perf_PID${PID}_${PROCESS_NAME}_$(date +%Y%m%d_%H%M%S).svg
    log_info "perf监控完成，火焰图已生成"
    
    # 移动top输出到最终位置
    mv $temp_file $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt
}

# 处理top输出数据
process_top_data() {
    log_info "开始处理CPU和内存占用数据..."
    
    # 处理top输出，提取CPU和内存占用率
    echo "ts,cpu,mem" > $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv
    
    # 使用awk处理整个文件，关联top行和PID行
    awk -v pid="$PID" '
    /^top - / {
        # 提取top行的时间戳
        timestamp = $3  # 时间戳在第3列
        next
    }
    /^[[:space:]]*'$PID'[[:space:]]/ {
        # 找到PID行，提取CPU和内存占用率
        cpu_usage = $9  # CPU占用率在第9列
        mem_usage = $10 # 内存占用率在第10列
        if (cpu_usage ~ /^[0-9]+\.?[0-9]*$/ && mem_usage ~ /^[0-9]+\.?[0-9]*$/) {
            print timestamp "," cpu_usage "," mem_usage
        }
    }' $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt >> $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv
    
    # 如果上面的方法不行，使用更简单的方法
    if [ ! -s $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv ] || [ "$(wc -l < $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv)" -le 1 ]; then
        log_warn "使用备用方法提取CPU和内存数据..."
        
        # 备用方法：直接按列位置提取
        grep -E "[[:space:]]*$PID[[:space:]]" $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt | awk '
        {
            # 直接提取第9列的CPU占用率和第10列的内存占用率
            cpu_usage = $9
            mem_usage = $10
            if (cpu_usage ~ /^[0-9]+\.?[0-9]*$/ && mem_usage ~ /^[0-9]+\.?[0-9]*$/) {
                printf "N/A,%.2f,%.2f\n", cpu_usage, mem_usage
            }
        }' >> $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv
    fi
}

# 计算百分位数
calculate_percentile() {
    local data_file=$1
    local percentile=$2
    
    if [ -s "$data_file" ]; then
        local total_lines=$(wc -l < "$data_file")
        local target_line=$((total_lines * percentile / 100))
        if [ $target_line -eq 0 ]; then
            target_line=1
        fi
        sed -n "${target_line}p" "$data_file"
    else
        echo "0"
    fi
}

# 生成CPU和内存综合报告
generate_cpu_mem_report() {
    echo "=== CPU和内存占用统计报告 ===" > $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    echo "PID: $PID (${PROCESS_NAME})" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    echo "监控时长: ${DURATION}秒" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    echo "监控时间: $(date)" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    echo "CPU阈值: ${CPU_THRESHOLD}%" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    echo "" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    
    if [ -s $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv ]; then
        # CPU统计信息
        echo "CPU占用率统计:" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        
        # 提取CPU数据并排序
        awk -F',' 'NR>1 {print $2}' $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv | sort -n > $OUTPUT_DIR/cpu_sorted.txt
        
        # 计算CPU统计信息
        awk -F',' 'NR>1 {
            cpu_sum += $2
            count++
            if ($2 > cpu_max) cpu_max = $2
            if (count == 1 || $2 < cpu_min) cpu_min = $2
        } END {
            if (count > 0) {
                cpu_avg = cpu_sum / count
                printf "  平均占用率: %.2f%%\n", cpu_avg
                printf "  最大占用率: %.2f%%\n", cpu_max
                printf "  最小占用率: %.2f%%\n", cpu_min
                printf "  采样次数: %d\n", count
            }
        }' $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        
        # 计算CPU百分位数
        if [ -s $OUTPUT_DIR/cpu_sorted.txt ]; then
            echo "  百分位数统计:" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P50: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/cpu_sorted.txt 50) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P90: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/cpu_sorted.txt 90) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P95: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/cpu_sorted.txt 95) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P99: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/cpu_sorted.txt 99) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        fi
        
        echo "" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        echo "内存占用率统计:" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        
        # 提取内存数据并排序
        awk -F',' 'NR>1 {print $3}' $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv | sort -n > $OUTPUT_DIR/mem_sorted.txt
        
        # 计算内存统计信息
        awk -F',' 'NR>1 {
            mem_sum += $3
            count++
            if ($3 > mem_max) mem_max = $3
            if (count == 1 || $3 < mem_min) mem_min = $3
        } END {
            if (count > 0) {
                mem_avg = mem_sum / count
                printf "  平均占用率: %.2f%%\n", mem_avg
                printf "  最大占用率: %.2f%%\n", mem_max
                printf "  最小占用率: %.2f%%\n", mem_min
                printf "  采样次数: %d\n", count
            }
        }' $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        
        # 计算内存百分位数
        if [ -s $OUTPUT_DIR/mem_sorted.txt ]; then
            echo "  百分位数统计:" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P50: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/mem_sorted.txt 50) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P90: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/mem_sorted.txt 90) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P95: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/mem_sorted.txt 95) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
            printf "    P99: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/mem_sorted.txt 99) >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
        fi
    else
        echo "警告: 未找到有效的CPU和内存占用数据" >> $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt
    fi
}

# 生成统计报告
generate_report() {
    local report_file=$1
    local csv_file=$2
    local metric_name=$3
    local column_index=$4
    
    echo "=== ${metric_name}占用统计报告 ===" > $report_file
    echo "PID: $PID (${PROCESS_NAME})" >> $report_file
    echo "监控时长: ${DURATION}秒" >> $report_file
    echo "监控时间: $(date)" >> $report_file
    echo "CPU阈值: ${CPU_THRESHOLD}%" >> $report_file
    echo "" >> $report_file
    
    if [ -s $csv_file ]; then
        echo "${metric_name}占用率统计:" >> $report_file
        
        # 提取数据并排序
        awk -F',' "NR>1 {print \$$column_index}" $csv_file | sort -n > $OUTPUT_DIR/${metric_name,,}_sorted.txt
        
        # 计算基本统计信息
        awk -F',' "NR>1 {
            sum += \$$column_index
            count++
            if (\$$column_index > max) max = \$$column_index
            if (count == 1 || \$$column_index < min) min = \$$column_index
        } END {
            if (count > 0) {
                avg = sum / count
                printf \"  平均占用率: %.2f%%\n\", avg
                printf \"  最大占用率: %.2f%%\n\", max
                printf \"  最小占用率: %.2f%%\n\", min
                printf \"  采样次数: %d\n\", count
            }
        }" $csv_file >> $report_file
        
        # 计算百分位数
        if [ -s $OUTPUT_DIR/${metric_name,,}_sorted.txt ]; then
            echo "  百分位数统计:" >> $report_file
            printf "    P50: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/${metric_name,,}_sorted.txt 50) >> $report_file
            printf "    P90: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/${metric_name,,}_sorted.txt 90) >> $report_file
            printf "    P95: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/${metric_name,,}_sorted.txt 95) >> $report_file
            printf "    P99: %.2f%%\n" $(calculate_percentile $OUTPUT_DIR/${metric_name,,}_sorted.txt 99) >> $report_file
        fi
    else
        echo "警告: 未找到有效的${metric_name}占用数据" >> $report_file
    fi
}

# 清理临时文件
cleanup() {
    rm -f $OUTPUT_DIR/cpu_sorted.txt $OUTPUT_DIR/mem_sorted.txt 
}

# 显示结果摘要
package_summary() {
    log_info "监控完成！"
    echo ""
    echo "输出文件:"
    echo "  - $OUTPUT_DIR/cpu_mem_usage_${PID}_${PROCESS_NAME}.csv (CSV格式的CPU和内存占用数据)"
    echo "  - $OUTPUT_DIR/cpu_mem_report_${PID}_${PROCESS_NAME}.txt (CPU和内存占用统计报告，包含百分位数)"
    echo "  - $OUTPUT_DIR/top_${PID}_${PROCESS_NAME}.txt (原始top输出)"
    
    # 检查是否有perf相关文件
    if [ -f "$OUTPUT_DIR/perf_env.data" ]; then
        echo "  - $OUTPUT_DIR/perf_env.data (perf原始数据)"
        echo "  - $OUTPUT_DIR/perf_*.svg (火焰图)"
    fi

    tar -czvf $OUTPUT_DIR.tar.gz $OUTPUT_DIR > /dev/null 2>&1
    echo "输出文件已打包: $OUTPUT_DIR.tar.gz"
}

# 主函数
main() {
    log_info "进程监控脚本 v$VERSION"
    if [ "$CONTINUOUS_MODE" = true ]; then
        log_info "PID: $PID (${PROCESS_NAME}), 模式: 持续监控 (按Ctrl+C停止)"
    else
        log_info "PID: $PID (${PROCESS_NAME}), 时长: ${DURATION}秒"
    fi
    
    # 参数验证和系统检查
    check_permissions
    check_pid
    configure_system
    
    # 创建输出目录和环境
    create_output_dir
    setup_environment
    
    # 根据参数决定监控方式
    if [ "$ENABLE_PERF" = true ]; then
        force_perf_monitoring
    else
        monitor_and_perf
    fi
    
    # 数据处理和报告生成（仅在非持续模式下执行）
    if [ "$CONTINUOUS_MODE" = false ]; then
        process_top_data
        generate_cpu_mem_report
        
        # 清理和总结
        cleanup
        package_summary
    fi
}

# 脚本入口
parse_arguments "$@"
main
