# Secrets

`<stack>.yaml` files here are SOPS-encrypted environment variables for one stack (keys and rules: [.sops.yaml](../.sops.yaml)).
Create one with `local/lab.sh secrets-init <stack>`, edit with `sops secrets/<stack>.yaml`, use with
`sops exec-env secrets/<stack>.yaml '<command>'`. See [docs/vm-installation.md](../docs/vm-installation.md#secrets).
