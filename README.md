# zabbix-domain-blacklist

This repository provides a Zabbix template and script to check if a specified SMTP domain is listed on Real-time Blackhole Lists (RBLs) using MXToolbox and/or HetrixTools APIs. The solution is designed for Zabbix integration and offers alerts based on customizable warning and critical thresholds.

</br>

## Features

- **Multi-API Support**: Queries MXToolbox and/or HetrixTools APIs to check domain blacklist status.
- **Customizable Thresholds**: Configurable warning and critical thresholds for the number of blacklists a domain appears on as listed.
- **JSON Output**: Provides structured JSON output with state (OK, WARNING, CRITICAL, UNKNOWN), blacklist count, blacklist names, and detailed messages.
- **Deduplication**: Normalizes and deduplicates blacklist names from both APIs for consistent reporting.
- **Error Handling**: Handles API errors, rate limits, and missing dependencies, reporting issues in Zabbix-compatible format.

## Requirements

- **Zabbix**: Version 6.4 or higher
- **OS**: GNU/Linux systems
- **Shell Script Dependencies**:
  - `curl`: For API requests.
  - `jq`: For JSON parsing.
  - `xargs`: For trimming whitespace in blacklist names.
- **API Keys** (at least one required):
  - MXToolbox API key (optional; register your own [MXToolbox account](https://mxtoolbox.com/) to get a key).
  - HetrixTools API key (optional; register your own [HetrixTools account](https://hetrixtools.com) to get a key).
- **Permissions**: Script must be executable (`chmod +x check_blacklist.sh`) and accessible by the Zabbix agent or server.

## Tested on
- **OS**: RHEL/Rocky (bash) and Debian/Ubuntu (dash)
- **Zabbix Server**: 6.4

## Installation (Zabbix Server)

### Install Script Dependencies

Ensure the required dependencies are installed on your system.

#### On RHEL/Rocky Linux

```bash
sudo dnf install -y curl jq coreutils
```

#### On Debian/Ubuntu

```bash
sudo apt-get update
sudo apt-get install -y curl jq coreutils
```

### Setup

1. **Clone or Download the Repository**:
   ```bash
   git clone https://github.com/a-stoyanov/zabbix-domain-blacklist.git
   cd zabbix-domain-blacklist
   ```

2. Copy shell script `check_blacklist.sh` to your Zabbix server external scripts dir (default: `/usr/lib/zabbix/externalscripts/`)
3. Make it executable (e.g. `chmod +x /usr/lib/zabbix/externalscripts/check_blacklist.sh`)
4. Import yaml template `zbx_domain_blacklist.yaml` to your zabbix server
5. Create a host with a domain name (e.g: `example.com`) as the Host name and attach the template to the host
6. **Configure API Keys**:
   - In Zabbix, go to the imported template (**Domain Blacklist**) under **Data Collection** > **Templates**.
   - Set the values for the macros `{$MXT_API_KEY}` and/or `{$HETRIX_API_KEY}` with valid API keys.
   - Optionally, adjust `{$RBL_COUNT_WARN}` (default: 1) and `{$RBL_COUNT_CRIT}` (default: 2) to customize alert thresholds.

## Usage

The script can be run manually for testing:

```bash
./check_blacklist.sh -d example.com -m <MXToolbox_API_Key>
./check_blacklist.sh -d example.com -x <HetrixTools_API_Key>
./check_blacklist.sh -d example.com -m <MXToolbox_API_Key> -x <HetrixTools_API_Key>
```

### Options

- `-d <domain>`: Required. The domain to check (e.g., `example.com`).
- `-m <mxtoolbox_api_key>`: Optional. MXToolbox API key for blacklist lookup.
- `-x <hetrix_api_key>`: Optional. HetrixTools API key for blacklist lookup.
- `-w <warning_count>`: Optional. Number of blacklists to trigger WARNING state (default: 1).
- `-c <critical_count>`: Optional. Number of blacklists to trigger CRITICAL state (default: 2).
- `-v`: Display script version and exit.
- `-h`: Display help message and exit.

### Example Output

```json
{
  "state": "OK",
  "blacklist_count": "0",
  "blacklist_names": "none",
  "message": "MXTOOLBOX check for example.com, HTTP status: 200, response size: 4563 bytes; HETRIXTOOLS check for example.com, HTTP status: 200, response size: 584 bytes, api_calls_left: 1938, blacklist_check_credits_left: 90"
}
```
### Example Alerts
![image](https://github.com/user-attachments/assets/357db1fa-9ba1-4f53-ac95-ab0516297082)


## Template Configuration

### Template Macros

| Macro                | Default Value | Description                                                                 |
|----------------------|---------------|-----------------------------------------------------------------------------|
| `{$HETRIX_API_KEY}`  | (empty)       | Specify a valid HetrixTools API key to use.                                 |
| `{$MXT_API_KEY}`     | (empty)       | Specify a valid MXToolbox API key to use.                                   |
| `{$RBL_COUNT_CRIT}`  | 2             | Threshold value for number of blacklists the domain appears on as listed before triggering a HIGH alert |
| `{$RBL_COUNT_WARN}`  | 1             | Threshold value for number of blacklists the domain appears on as listed before triggering a WARNING alert|

### Template Items

| Name               | Type       | Key                                                                 | Value Type | Delay | Preprocessing                                  | Description                                                                 |
|--------------------|------------|--------------------------------------------------------------------|------------|-------|------------------------------------------------|-----------------------------------------------------------------------------|
| Blacklist Names    | DEPENDENT  | `blacklist_count.blacklist_names`                                  | TEXT       | 0     | JSONPATH: `$.blacklist_names` | Extracts the list of blacklist names from the script's JSON output.          |
| Blacklist Count    | DEPENDENT  | `check_blacklist.blacklist_count`                                  | FLOAT      | 0     | JSONPATH: `$.blacklist_count` | Extracts the number of blacklists the domain is listed on.                   |
| Message            | DEPENDENT  | `check_blacklist.message`                                          | TEXT       | 0     | JSONPATH: `$.message`         | Extracts the detailed message from the script's JSON output.                 |
| Check Blacklist    | EXTERNAL   | `check_blacklist.sh[...]`                                          | TEXT       | 1h    | None                          | Runs the external script to check blacklist status.                          |
| State              | DEPENDENT  | `check_blacklist.state`                                            | TEXT       | 0     | JSONPATH: `$.state`           | Extracts the state (OK, WARNING, CRITICAL, UNKNOWN) from the JSON output.    |

### Template Triggers

| Name                                          | Expression                                                                                          | Priority  | Operational Data                                   | Description                                                                 |
|-----------------------------------------------|-----------------------------------------------------------------------------------------------------|-----------|---------------------------------------------------|-----------------------------------------------------------------------------|
| Domain Blacklist: {HOST.HOST} - {ITEM.LASTVALUE2} | `last(/Domain Blacklist/check_blacklist.state)="UNKNOWN" and last(/Domain Blacklist/check_blacklist.message)<>0` | NOT CLASSIFIED   | None                                              | Alerts if the script returns an UNKNOWN state (e.g., API errors).            |
| Domain Blacklist: {HOST.HOST} has been blacklisted | `last(/Domain Blacklist/check_blacklist.state)="CRITICAL" and last(/Domain Blacklist/check_blacklist.blacklist_count)>={$RBL_COUNT_CRIT} and last(/Domain Blacklist/blacklist_count.blacklist_names)<>0` | HIGH      | `{ITEM.LASTVALUE2} time(s) on RBL(s): [{ITEM.LASTVALUE3}]` | Alerts if the domain is listed on `{$RBL_COUNT_CRIT}` or more blacklists.    |
| Domain Blacklist: {HOST.HOST} has been blacklisted | `last(/Domain Blacklist/check_blacklist.state)="WARNING" and last(/Domain Blacklist/check_blacklist.blacklist_count)>={$RBL_COUNT_WARN} and last(/Domain Blacklist/blacklist_count.blacklist_names)<>0` | WARNING   | `{ITEM.LASTVALUE2} time(s) on RBL(s): [{ITEM.LASTVALUE3}]` | Alerts if the domain is listed on `{$RBL_COUNT_WARN}` or more blacklists.    |

## Notes

- The script requires at least one API key (MXToolbox or HetrixTools) to work.
- The critical threshold must be greater than the warning threshold.
- Temporary files are created in a unique directory (e.g., `/tmp/check_blacklist.XXXXXX`) and cleaned up on exit.
- Debug logs are written to `$tmpdir/debug.txt`, `$tmpdir/mxtoolbox_raw_names.txt`, and `$tmpdir/hetrix_raw_names.txt` for troubleshooting.
- HetrixTools API rate limits are handled by reporting an UNKNOWN state if exceeded.

## License

This project is licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.
