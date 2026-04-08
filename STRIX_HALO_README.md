# SentiNL: AMD Strix Halo Fine-Tuning Guide

This guide documents the exact, battle-tested steps required to fine-tune massive language models (like Gemma 4 2B) natively on an **AMD Strix Halo APU (RDNA 3.5 / gfx1151)** running Ubuntu 24.04.

Because APUs use Unified Memory, they are capable of loading massive models that normally require expensive enterprise Nvidia GPUs. However, they require strict host-level and container-level overrides to prevent out-of-memory (OOM) segfaults and driver crashes.

---

## Phase 1: Ubuntu Host Configuration (CRITICAL)

By default, Linux places a strict artificial cap on how much system RAM the integrated GPU can allocate. If a model tries to load a massive tensor (like Gemma's 256k vocabulary matrix), the OS kills the process instantly. We must unlock the APU's access to the full 128GB of Unified Memory.

### 1. Update GRUB Boot Parameters
1. Open your Ubuntu terminal and edit the GRUB config:
   ```bash
   sudo nano /etc/default/grub
   ```
2. Find the line starting with `GRUB_CMDLINE_LINUX_DEFAULT` and append these exact flags inside the quotes:
   ```text
   amd_iommu=off amdttm.pages_limit=33554432 ttm.pages_limit=33554432 amdgpu.gttsize=131072
   ```
   *(This disables IOMMU latency, allows massive contiguous page-locked memory chunks, and explicitly sets the Graphics Translation Table limit to 128 GiB).*
3. Update GRUB:
   ```bash
   sudo update-grub
   ```
4. **SHUT DOWN YOUR COMPUTER** (Do a full cold boot, not a restart) to apply the BIOS-level memory changes.

### 2. Configure UDEV Rules for Container GPU Access
So the Docker/Podman container can natively talk to your Radeon GPU without requiring root, apply these rules:
```bash
sudo tee /etc/udev/rules.d/99-amd-kfd.rules > /dev/null <<EOF
SUBSYSTEM=="kfd", GROUP="render", MODE="0666", OPTIONS+="last_rule"
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="render", MODE="0666", OPTIONS+="last_rule"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=kfd --action=change
sudo udevadm trigger --subsystem-match=drm --action=change
```

---

## Phase 2: Setup the ROCm Toolbox

We use a specialized Fedora-based Podman container (`shantur`'s Strix Halo toolbox) that has been deeply patched with ROCm 7 Nightly and RCCL fixes to support the `gfx1151` architecture.

### 1. Install & Create the Toolbox
```bash
sudo apt install podman-toolbox
toolbox --verbose create toolbox-all --image docker.io/shantur/amd-strix-halo-fine-tuning-toolboxes:all-latest
```

### 2. Enter the Toolbox
```bash
export PYTHONPATH=$(pwd)
source .venv/bin/activate
toolbox enter toolbox-all
```
*(Note: Podman Toolbox automatically mounts your host's Home directory, so your local code and models are instantly available inside the container!)*

### 3. Upgrade Hugging Face Libraries (Bleeding-Edge Fix)
To support the newest model architectures (like `Gemma4ClippableLinear` layers) and the latest `trl` 0.24+ `SFTConfig` standards, we must upgrade the container's built-in libraries.

Run this **inside the toolbox**:
```bash
PYTHONNOUSERSITE=1 sudo python3 -m pip install --upgrade transformers datasets accelerate peft trl --break-system-packages
```
*(The `PYTHONNOUSERSITE=1` flag is crucial: it prevents the container from accidentally loading outdated packages from your Ubuntu host's `~/.local` folder).*

---

## Phase 3: Data & Model Preparation

### 1. Generate the Dataset
Run the python script we created to automatically download the phishing and spam data from Hugging Face and format it into a `scam_dataset.jsonl` file.
```bash
PYTHONNOUSERSITE=1 python3 prepare_scam_dataset_light.py
```

### 2. Download the Model Offline
Hugging Face's Python API often hangs silently when downloading massive 10GB `safetensors` files from their new XetHub storage backend (`xet-read-token` deadlocks). Download the model manually using the CLI:
```bash
huggingface-cli download google/gemma-4-E2b-it --local-dir ./local-gemma-model
```

---

## Phase 4: Fine-Tuning on the APU

We run a specialized, APU-safe training script (`finetune_hf_toolbox.py`).

**Key APU-Specific Code Modifications Used:**
- `torch_dtype=torch.bfloat16`: Runs natively and ultra-fast on RDNA 3.5.
- `attn_implementation="eager"`: **CRITICAL.** This disables PyTorch's default Flash Attention / Triton kernels, which currently contain incompatible hardware instructions that cause silent core dumps (segfaults) on spoofed Strix Halo architectures.
- `target_modules=["q_proj.linear", ...]`: Safely bypasses `peft` versioning bugs by targeting the inner linear wrappers of the newest Gemma models.
- `SFTConfig(...)`: Uses the modern TRL 0.24+ syntax for defining sequence lengths and processing classes.

### 1. Launch Training
Run the script inside your toolbox:
```bash
PYTHONNOUSERSITE=1 python3 finetune_hf_toolbox.py
```
Because of your 128GB of Unified Memory, the script safely uses a high batch size without crashing, loading the entire pipeline directly into VRAM.

### 2. Exporting to Flutter (GGUF)
Once training completes, the LoRA adapters will be saved to `gemma-scam-toolbox-output/adapter`.

To deploy this to the SentiNL Flutter mobile app, use the standard `llama.cpp` pipeline to merge the adapter into the base model and quantize it to a 4-bit `Q4_K_M.gguf` file!
