#!/usr/bin/env bash
# shellcheck disable=SC2016 # HCL interpolation strings below must remain literal.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
template="${MICROOS_TEMPLATE:-$repo_root/packer-template/hcloud-microos-snapshots.pkr.hcl}"
verifier="$repo_root/packer-template/scripts/verify-microos-image.sh"
packer_bin="${PACKER_BIN:-packer}"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

require_text() {
  local text="$1"
  local message="$2"
  grep -Fq "$text" "$template" || fail "$message"
}

require_text 'required_version = "= 1.16.0"' 'Packer must be pinned exactly'
require_text 'version = "= 1.7.2"' 'hcloud plugin must be pinned exactly'
require_text 'filebase64("${path.root}/keys/opensuse-project-signing-key.asc")' 'vendored openSUSE key is not embedded'
require_text 'filebase64("${path.root}/keys/rancher-ci-signing-key.asc")' 'vendored Rancher key is not embedded'
require_text 'filebase64("${path.root}/scripts/verify-microos-image.sh")' 'MicroOS verifier is not embedded'
require_text 'filebase64("${path.root}/scripts/install-verified-rancher-rpm.sh")' 'verified Rancher RPM installer is not embedded'
require_text 'filebase64("${path.root}/scripts/verify-rancher-rpm.sh")' 'verified Rancher RPM verifier is not embedded'

require_text '015f2b6b2ec1cd9480e372cea97cf4cd8e75869005ff2200b617629532dc05e1' 'reviewed x86 MicroOS image digest is missing'
require_text 'd3e080c1bff16fc685c1de1c842a0bdf3653637e88514cbfc47c711c44fb9401' 'reviewed ARM MicroOS image digest is missing'
require_text 'aaaf5a0632d77db8c5808c6d1097167c934602639d628526c1ec0bd9cb2dd745' 'reviewed k3s-selinux MicroOS RPM digest is missing'
require_text '0c3b1184293a2f47482d6333aa183b91ed9351889925b55760208a37a1f68a39' 'reviewed rke2-selinux MicroOS RPM digest is missing'

require_text 'transactional-update --continue shell' 'SELinux RPM installation must run transactionally'
require_text 'case "${var.selinux_package_to_install}" in' 'k3s/RKE2 package selection is missing'
require_text 'RANCHER_SIGNING_KEY_FILE=/var/tmp/rancher-ci-signing-key.asc' 'RPM verification does not use the vendored Rancher key'
require_text 'verify_baked_selinux_package' 'post-reboot SELinux RPM verification is missing'
require_text 'prepare_microos_first_boot = <<-EOT' 'pre-first-boot MicroOS preparation is missing'
require_text 'blockdev --rereadpt /dev/sda || true' 'written MicroOS partition table is not refreshed before inspection'
require_text 'for attempt in $(seq 1 30); do' 'written MicroOS ROOT discovery is not bounded'
require_text 'root_device="$(blkid -L ROOT 2>/dev/null || true)"' 'written MicroOS ROOT discovery does not use its filesystem label'
require_text '/dev/sda*) break ;;' 'written MicroOS ROOT discovery is not constrained to the target disk'
require_text 'chroot "$mount_dir" /usr/bin/busybox --list | grep -Fxq udhcpc' 'the bundled udhcpc applet is not fail-closed verified'
require_text "'    dhcp_client_priority: [udhcpc]'" 'cloud-init is not configured to avoid the blocking dhcpcd metadata probe'
require_text 'mount -o subvol=@/usr/local "$root_device" "$mount_dir/usr/local"' 'persistent /usr/local is not mounted before installing udhcpc'
require_text 'condition     = can(regex("^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$", var.timezone))' 'timezone input is not constrained to safe zoneinfo path components'
require_text 'inline       = [local.finalize_snapshot]' 'transactional snapshot finalizer is missing'

[[ "$(grep -Fc '${local.prepare_microos_first_boot}' "$template")" == 2 ]] \
  || fail 'both architecture write paths must prepare cloud-init before first boot'

[[ "$(grep -Fc 'inline       = [local.finalize_snapshot]' "$template")" == 2 ]] \
  || fail 'both architecture builds must run transactional snapshot finalization'
if grep -Fq 'verify_final_state' "$template"; then
  fail 'the unbooted final cleanup snapshot must not have an impossible post-reboot verifier'
fi
if grep -Fq 'timedatectl' "$template"; then
  fail 'transactional cleanup must set /etc/localtime directly instead of using timedatectl in a chroot'
fi

if grep -Eq 'rpm[[:space:]]+--import[[:space:]]+https?://' "$template"; then
  fail 'template imports a remote RPM signing key'
fi
if grep -Eq 'zypper([[:space:]][^[:space:]]+)*[[:space:]]+https?://' "$template"; then
  fail 'template installs an unverified remote RPM URL'
fi
if grep 'qemu-img convert' "$template" | grep -Eq '(ls|grep|find|\$\(|`|\*|\?|\[)'; then
  fail 'qemu-img input is selected dynamically'
fi

require_text 'snapshot_build_timestamp = formatdate(' 'snapshot timestamp is missing'
require_text 'snapshot_build_id        = substr(replace(uuidv4()' 'snapshot random build ID is missing'
require_text 'snapshot_name = "OpenSUSE MicroOS x86 ${upper(var.selinux_package_to_install)} ${local.snapshot_build_timestamp}-${local.snapshot_build_id} by Kube-Hetzner"' 'x86 snapshot name is not collision-resistant'
require_text 'snapshot_name = "OpenSUSE MicroOS ARM ${upper(var.selinux_package_to_install)} ${local.snapshot_build_timestamp}-${local.snapshot_build_id} by Kube-Hetzner"' 'ARM snapshot name is not collision-resistant'

for variable in \
  opensuse_microos_x86_mirror_link \
  opensuse_microos_x86_checksum_link \
  opensuse_microos_x86_signature_link \
  opensuse_microos_arm_mirror_link \
  opensuse_microos_arm_checksum_link \
  opensuse_microos_arm_signature_link \
  opensuse_microos_x86_mirror_authorization_header \
  opensuse_microos_arm_mirror_authorization_header; do
  block="$(awk -v name="$variable" '
    $0 == "variable \"" name "\" {" { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$template")"
  grep -Fq 'sensitive   = true' <<< "$block" || fail "$variable must be marked sensitive"
done

if grep -Fq 'opensuse_microos_mirror_authorization_header' "$template"; then
  fail 'a shared x86/ARM mirror credential can cross architecture or origin boundaries'
fi
require_text 'MIRROR_AUTHORIZATION_HEADER=${var.opensuse_microos_x86_mirror_authorization_header}' 'x86 build does not use its dedicated mirror credential'
require_text 'MIRROR_AUTHORIZATION_HEADER=${var.opensuse_microos_arm_mirror_authorization_header}' 'ARM build does not use its dedicated mirror credential'
require_text 'CUSTOM_IMAGE=${local.opensuse_microos_x86_is_custom ? 1 : 0}' 'x86 build does not preserve explicit official-URL compatibility'
require_text 'CUSTOM_IMAGE=${local.opensuse_microos_arm_is_custom ? 1 : 0}' 'ARM build does not preserve explicit official-URL compatibility'
[[ "$(grep -Fc 'use_env_var_file = true' "$template")" == 2 ]] \
  || fail 'both image verifier provisioners must transport secrets through Packer environment files'

command -v "$packer_bin" >/dev/null 2>&1 || fail 'Packer is required for rendered-local checks'
[[ -x "$verifier" ]] || fail 'MicroOS verifier must be executable'

x86_path=/root/openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2
arm_path=/root/openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2
x86_write_script="$(printf 'local.write_x86_image\n' | "$packer_bin" console "$template")"
arm_write_script="$(printf 'local.write_arm_image\n' | "$packer_bin" console "$template")"
finalize_script="$(printf 'local.finalize_snapshot\n' | "$packer_bin" console -var 'timezone=Europe/Madrid' "$template")"
grep -Fq "qemu-img convert -p -f qcow2 -O host_device '$x86_path' /dev/sda" <<< "$x86_write_script" \
  || fail 'rendered x86 conversion does not use the fixed verified path'
grep -Fq "qemu-img convert -p -f qcow2 -O host_device '$arm_path' /dev/sda" <<< "$arm_write_script" \
  || fail 'rendered ARM conversion does not use the fixed verified path'

for write_script in "$x86_write_script" "$arm_write_script"; do
  for required_first_boot_text in \
    'blockdev --rereadpt /dev/sda || true' \
    'for attempt in $(seq 1 30); do' \
    'root_device="$(blkid -L ROOT 2>/dev/null || true)"' \
    '/dev/sda*) break ;;' \
    'written MicroOS ROOT filesystem is not Btrfs' \
    'chroot "$mount_dir" /usr/bin/busybox --list | grep -Fxq udhcpc' \
    'mount -o subvol=@/usr/local "$root_device" "$mount_dir/usr/local"' \
    'ln -snf /usr/bin/busybox "$mount_dir/usr/local/sbin/udhcpc"' \
    "'system_info:'" \
    "'  network:'" \
    "'    dhcp_client_priority: [udhcpc]'"; do
    grep -Fq "$required_first_boot_text" <<< "$write_script" \
      || fail "rendered MicroOS write path is missing: $required_first_boot_text"
  done

  convert_line="$(grep -n -m1 'qemu-img convert' <<< "$write_script" | cut -d: -f1)"
  priority_line="$(grep -n -m1 'dhcp_client_priority: \[udhcpc\]' <<< "$write_script" | cut -d: -f1)"
  reboot_line="$(grep -n -m1 'sleep 1 && udevadm settle && reboot' <<< "$write_script" | cut -d: -f1)"
  [[ "$convert_line" -lt "$priority_line" && "$priority_line" -lt "$reboot_line" ]] \
    || fail 'MicroOS udhcpc configuration must be written after conversion and before first boot'
done

for required_cleanup_text in \
  "transactional-update --continue shell" \
  "rm -f /etc/ssh/ssh_host_*" \
  'rm -f /root/.ssh/authorized_keys /root/.ssh/authorized_keys.kube-hetzner' \
  'SSH authorized keys remain in the persistent root subvolume' \
  "install -m 0644 /dev/null /etc/NetworkManager/NetworkManager.conf" \
  "timezone='Europe/Madrid'" \
  'ln -snf "$zoneinfo" /etc/localtime' \
  "printf '%s\\n' \"\$timezone\" > /etc/timezone" \
  "find /etc/ssh -maxdepth 1 -name 'ssh_host_*'" \
  '[ -f /etc/NetworkManager/NetworkManager.conf ]' \
  'persisted_zone="$(readlink -f -- /etc/localtime)"' \
  '[ -f /etc/timezone ]'; do
  grep -Fq "$required_cleanup_text" <<< "$finalize_script" \
    || fail "rendered transactional finalizer is missing: $required_cleanup_text"
done

if ! awk '
  /transactional-update --continue shell/ { inside = 1; next }
  inside && /^[[:space:]]*EOF$/ { inside = 0; next }
  !inside && /rm -f \/root\/[.]ssh\/authorized_keys/ { found = 1 }
  END { exit(found ? 0 : 1) }
' <<< "$finalize_script"; then
  fail 'persistent /root authorized-key cleanup must run outside the transactional shell'
fi

for required_booted_selinux_check in \
  'rpm -q --queryformat' \
  'rpm -V "$package_name"' \
  'semodule -l' \
  '"$(getenforce)" = "Enforcing"'; do
  grep -Fq "$required_booted_selinux_check" <<< "$finalize_script" \
    || fail "rendered pre-finalization SELinux gate is missing: $required_booted_selinux_check"
done

[[ "$(grep -Fc 'transactional-update --continue shell' <<< "$finalize_script")" == 1 ]] \
  || fail 'snapshot finalization must use exactly one final transactional shell'
booted_verification_line="$(grep -n -m1 'rpm -q --queryformat' <<< "$finalize_script" | cut -d: -f1)"
final_transaction_line="$(grep -n -m1 'transactional-update --continue shell' <<< "$finalize_script" | cut -d: -f1)"
[[ "$booted_verification_line" -lt "$final_transaction_line" ]] \
  || fail 'booted SELinux verification must complete before final transactional cleanup starts'
finalize_commands="$(grep -Fv 'Second reboot successful' <<< "$finalize_script")"
if grep -Eq '(^|[;&|[:space:]])(reboot|shutdown)([;&|[:space:]]|$)|systemctl[[:space:]]+reboot' <<< "$finalize_commands"; then
  fail 'the committed final cleanup snapshot must remain unbooted for Packer capture'
fi

unsafe_timezone='../../etc/passwd'
if [[ "$unsafe_timezone" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
  fail 'unsafe timezone traversal input was accepted'
fi

k3s_install_script="$(printf 'local.install_packages\n' | "$packer_bin" console \
  -var 'selinux_package_to_install=k3s' "$template")"
rke2_install_script="$(printf 'local.install_packages\n' | "$packer_bin" console \
  -var 'selinux_package_to_install=rke2' "$template")"
custom_digest=1111111111111111111111111111111111111111111111111111111111111111
custom_rke2_digest=2222222222222222222222222222222222222222222222222222222222222222
custom_k3s_install_script="$(printf 'local.install_packages\n' | "$packer_bin" console \
  -var 'selinux_package_to_install=k3s' \
  -var 'k3s_selinux_version=v1.7.stable.1' \
  -var "k3s_selinux_expected_sha256=$custom_digest" \
  "$template")"
custom_rke2_install_script="$(printf 'local.install_packages\n' | "$packer_bin" console \
  -var 'selinux_package_to_install=rke2' \
  -var 'rke2_selinux_version=v0.23.stable.1' \
  -var "rke2_selinux_expected_sha256=$custom_rke2_digest" \
  "$template")"

for rendered_script in "$k3s_install_script" "$rke2_install_script" "$custom_k3s_install_script" "$custom_rke2_install_script"; do
  grep -Fq "transactional-update --continue shell" <<< "$rendered_script" \
    || fail 'rendered SELinux package installation is not transactional'
  grep -Fq 'RANCHER_RPM_VERIFIER_FILE=/var/tmp/verify-rancher-rpm.sh' <<< "$rendered_script" \
    || fail 'rendered SELinux package installation does not call the verified RPM helper'
  grep -Fq 'RANCHER_SIGNING_KEY_FILE=/var/tmp/rancher-ci-signing-key.asc' <<< "$rendered_script" \
    || fail 'rendered SELinux package installation does not use the vendored Rancher key'
  install_transaction_line="$(grep -n -m1 'transactional-update --continue shell' <<< "$rendered_script" | cut -d: -f1)"
  install_reboot_line="$(grep -n -m1 'sleep 1 && udevadm settle && reboot' <<< "$rendered_script" | cut -d: -f1)"
  [[ "$install_transaction_line" -lt "$install_reboot_line" ]] \
    || fail 'SELinux transaction must complete before its verification reboot'
done

install_provisioner_lines="$(grep -nF 'inline            = [local.install_packages]' "$template" | cut -d: -f1)"
finalizer_provisioner_lines="$(grep -nF 'inline       = [local.finalize_snapshot]' "$template" | cut -d: -f1)"
[[ "$(wc -l <<< "$install_provisioner_lines" | tr -d ' ')" == 2 \
  && "$(wc -l <<< "$finalizer_provisioner_lines" | tr -d ' ')" == 2 ]] \
  || fail 'both architecture builds must contain one install/reboot and one finalizer provisioner'
for index in 1 2; do
  install_line="$(sed -n "${index}p" <<< "$install_provisioner_lines")"
  finalizer_line="$(sed -n "${index}p" <<< "$finalizer_provisioner_lines")"
  [[ "$install_line" -lt "$finalizer_line" ]] \
    || fail 'each architecture must verify the booted install before final snapshot cleanup'
done

grep -Fq 'K3S_TAG="v1.6.stable.1"' <<< "$k3s_install_script" \
  || fail 'rendered k3s branch does not use the reviewed release tag'
grep -Fq 'K3S_URL="https://github.com/k3s-io/k3s-selinux/releases/download/$K3S_TAG/$K3S_PACKAGE"' <<< "$k3s_install_script" \
  || fail 'rendered k3s branch does not use the expected repository URL'
grep -Fq 'EXPECTED_RPM_SHA256=aaaf5a0632d77db8c5808c6d1097167c934602639d628526c1ec0bd9cb2dd745' <<< "$k3s_install_script" \
  || fail 'rendered k3s branch does not use its reviewed digest'

grep -Fq 'RKE2_TAG="v0.22.stable.1"' <<< "$rke2_install_script" \
  || fail 'rendered RKE2 branch does not use the reviewed release tag'
grep -Fq 'RKE2_URL="https://github.com/rancher/rke2-selinux/releases/download/$RKE2_TAG/$RKE2_PACKAGE"' <<< "$rke2_install_script" \
  || fail 'rendered RKE2 branch does not use the expected repository URL'
grep -Fq 'EXPECTED_RPM_SHA256=0c3b1184293a2f47482d6333aa183b91ed9351889925b55760208a37a1f68a39' <<< "$rke2_install_script" \
  || fail 'rendered RKE2 branch does not use its reviewed digest'

grep -Fq 'K3S_TAG="v1.7.stable.1"' <<< "$custom_k3s_install_script" \
  || fail 'rendered custom k3s branch does not use the explicit release tag'
grep -Fq "EXPECTED_RPM_SHA256=$custom_digest" <<< "$custom_k3s_install_script" \
  || fail 'rendered custom k3s branch does not use the explicit digest pin'

grep -Fq 'RKE2_TAG="v0.23.stable.1"' <<< "$custom_rke2_install_script" \
  || fail 'rendered custom RKE2 branch does not use the explicit release tag'
grep -Fq "EXPECTED_RPM_SHA256=$custom_rke2_digest" <<< "$custom_rke2_install_script" \
  || fail 'rendered custom RKE2 branch does not use the explicit digest pin'

official_x86_url=https://download.opensuse.org/tumbleweed/appliances/openSUSE-MicroOS.x86_64-ContainerHost-OpenStack-Cloud.qcow2
official_arm_url=https://download.opensuse.org/ports/aarch64/tumbleweed/appliances/openSUSE-MicroOS.aarch64-ContainerHost-OpenStack-Cloud.qcow2
explicit_official_x86_digest="$(printf 'local.opensuse_microos_x86_expected_sha256_computed\n' | "$packer_bin" console \
  -var "opensuse_microos_x86_mirror_link=$official_x86_url" "$template")"
explicit_official_arm_digest="$(printf 'local.opensuse_microos_arm_expected_sha256_computed\n' | "$packer_bin" console \
  -var "opensuse_microos_arm_mirror_link=$official_arm_url" "$template")"
[[ "$explicit_official_x86_digest" == 015f2b6b2ec1cd9480e372cea97cf4cd8e75869005ff2200b617629532dc05e1 ]] \
  || fail 'explicit legacy x86 official URL no longer selects official digest mode'
[[ "$explicit_official_arm_digest" == d3e080c1bff16fc685c1de1c842a0bdf3653637e88514cbfc47c711c44fb9401 ]] \
  || fail 'explicit legacy ARM official URL no longer selects official digest mode'

custom_x86_image_digest=3333333333333333333333333333333333333333333333333333333333333333
custom_arm_image_digest=4444444444444444444444444444444444444444444444444444444444444444
rendered_custom_x86_digest="$(printf 'local.opensuse_microos_x86_expected_sha256_computed\n' | "$packer_bin" console \
  -var 'opensuse_microos_x86_mirror_link=https://mirror.example.invalid/x86.qcow2' \
  -var "opensuse_microos_x86_expected_sha256=$custom_x86_image_digest" "$template")"
rendered_custom_arm_digest="$(printf 'local.opensuse_microos_arm_expected_sha256_computed\n' | "$packer_bin" console \
  -var 'opensuse_microos_arm_mirror_link=https://mirror.example.invalid/arm.qcow2' \
  -var "opensuse_microos_arm_expected_sha256=$custom_arm_image_digest" "$template")"
[[ "$rendered_custom_x86_digest" == "$custom_x86_image_digest" ]] \
  || fail 'rendered custom x86 image does not use its explicit digest pin'
[[ "$rendered_custom_arm_digest" == "$custom_arm_image_digest" ]] \
  || fail 'rendered custom ARM image does not use its explicit digest pin'

printf 'PASS: MicroOS Packer template enforces verified images, boot-verified SELinux state, unbooted transactional cleanup, redacted mirror inputs, and collision-resistant snapshots.\n'
