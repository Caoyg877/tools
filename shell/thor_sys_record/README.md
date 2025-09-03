# Thor 系统记录工具

Linux进程性能监控工具，支持CPU/内存监控和火焰图生成。

## 快速使用

```bash
# 基本监控（需要root权限）
sudo ./record.sh <PID> <监控秒数>

# 示例：监控进程1234，持续10秒
sudo ./record.sh 1234 10

# 持续监控直到Ctrl+C停止
sudo ./record.sh 1234 -1
```

## 参数选项

- `--perf` - 强制启用perf性能分析
- `--threshold N` - 设置CPU阈值，超过后自动启动perf（默认100%）
- `--help` - 显示帮助信息

```bash
# 强制perf分析
sudo ./record.sh 1234 10 --perf

# 自定义CPU阈值
sudo ./record.sh 1234 10 --threshold 80
```

## 输出文件

监控完成后生成以下文件：

```
record_output_<进程名>_PID<PID>_<时间>/
├── cpu_mem_usage_*.csv    # CPU和内存数据
├── cpu_mem_report_*.txt   # 统计报告
├── top_*.txt             # 原始监控数据
└── perf_*.svg           # 火焰图（如果触发perf）
```

## 系统要求

- Linux系统
- Root权限
- 已安装perf工具

## 功能特点

- 实时监控指定进程CPU和内存使用率
- CPU使用率超过阈值时自动生成火焰图
- 生成详细统计报告（包含百分位数）
- 支持持续监控模式