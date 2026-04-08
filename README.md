# SentiNL - On-Device Scam Detector for Seniors

SentiNL is a completely offline, privacy-first AI scam detection application for Android. It uses a fine-tuned **Gemma 4 2B** language model running entirely on your phone's processor via `llama.cpp` to analyze text messages for phishing, smishing, and social engineering attempts.

This repository contains the complete pipeline: from dataset generation and AMD APU fine-tuning to the Python FastAPI backend and the Flutter mobile app.

---

## 🌟 Core Features
* **100% Offline AI**: Scans texts natively on-device. No sensitive data is ever sent to a cloud API.
* **On-Device OCR**: Extracts text from screenshots instantly using Google ML Kit.
* **Over-The-Air (OTA) Blacklist Updates**: Syncs with a Python backend to securely download the latest scam URL databases.
* **Cloud Fallback Web Verification**: Securely queries DuckDuckGo for live context if a scam is completely novel.

---

## 🛠️ Step 1: Host Machine Setup (AMD Strix Halo APUs)

Fine-tuning a 2-Billion parameter model requires massive Unified Memory. By default, Ubuntu 24.04 physically caps APU graphics memory allocations. **You must unlock your RAM and set up UDEV rules before training.**

### 1. Unlock APU Unified Memory (GRUB)
1. Open terminal: `sudo nano /etc/default/grub`
2. Add these flags to `GRUB_CMDLINE_LINUX_DEFAULT`:
   `amd_iommu=off amdttm.pages_limit=33554432 ttm.pages_limit=33554432 amdgpu.gttsize=131072`
3. Apply: `sudo update-grub`
4. **Cold Boot:** Shut down the computer completely, then turn it back on.

### 2. Configure UDEV Rules for Docker/Podman
Allow containerized access to the `/dev/kfd` graphics driver:
```bash
sudo tee /etc/udev/rules.d/99-amd-kfd.rules > /dev/null <<INJECT
SUBSYSTEM=="kfd", GROUP="render", MODE="0666", OPTIONS+="last_rule"
SUBSYSTEM=="drm", KERNEL=="card[0-9]*", GROUP="render", MODE="0666", OPTIONS+="last_rule"
INJECT
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=kfd --action=change
sudo udevadm trigger --subsystem-match=drm --action=change
```

---

## 🧠 Step 2: Fine-Tuning the Gemma 4 Model

We use a specialized Fedora Podman container patched with ROCm 7 Nightly to bypass host-level RCCL bugs.

### 1. Create and Enter the Toolbox
```bash
sudo apt install podman-toolbox
toolbox create toolbox-all --image docker.io/shantur/amd-strix-halo-fine-tuning-toolboxes
toolbox enter toolbox-all
```

### 2. Upgrade Hugging Face Ecosystem
Inside the toolbox, force-upgrade to the latest Hugging Face libraries (requires `PYTHONNOUSERSITE=1` to prevent path pollution from your Ubuntu host):
```bash
PYTHONNOUSERSITE=1 sudo python3 -m pip install --upgrade transformers datasets accelerate peft trl --break-system-packages
```

### 3. Run the All-in-One Training Pipeline
Navigate to the project directory and run the fully automated training script. 
* *This script automatically downloads the UCI SMS & Phishing datasets, formats them, loads the base Gemma model in `bfloat16` using `eager` attention (to prevent Triton segfaults), trains the LoRA adapters, merges the model, compiles `llama.cpp` using CMake, and outputs the final `Q4_K_M` GGUF file!*

```bash
cd ~/Work/Projects/Code/sentinl/
PYTHONNOUSERSITE=1 python3 finetune_hf_toolbox.py
```
**Output:** Your finalized mobile model will be saved to `gemma-scam-toolbox-output/gemma-4-E2b-scam-q4_k_m.gguf`.

---

## 🌐 Step 3: Run the Backend API

The Python backend handles the OTA SQLite database updates and the DuckDuckGo "Check Web" fallback.

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install fastapi uvicorn pydantic ddgs googlesearch-python

# Start the API server
python3 -m uvicorn main:app --host 0.0.0.0 --port 8000 --timeout-keep-alive 3600
```

*(Note: The `ddgs` library is heavily restricted by DuckDuckGo. We implemented a strict `timeout=10` in `main.py` so that if your IP is rate-limited, it returns a safe "Search Error" instead of infinitely freezing the FastAPI server).*

---

## 📱 Step 4: Deploying the Android App

To prevent the massive 3.2GB GGUF file from dropping over flaky local Wi-Fi, the fastest method for developers is to push the model directly over a USB cable using ADB.

### 1. USB Sideload the AI Model
Plug in your Android phone (with USB Debugging enabled) and push the file directly to the app's external files directory:
```bash
adb push gemma-scam-toolbox-output/gemma-4-E2b-scam-q4_k_m.gguf /sdcard/Android/data/com.example.sentinl/files/gemma-4-E2b-scam-q4_k_m.gguf
```

### 2. Compile and Run the Flutter App
The Flutter app dynamically accepts your PC's IP address as an environment variable so no sensitive IPs are hardcoded into the Git repository.

```bash
cd mobile
flutter pub get

# Run the app (Replace 192.168.2.232 with your actual computer's Wi-Fi IP address)
flutter run --release \
  --dart-define=BACKEND_URL=http://192.168.2.232:8000 \
  --dart-define=MODEL_URL=http://192.168.2.232:8080/gemma-4-E2b-scam-q4_k_m.gguf
```
*(Note: Because you already sideloaded the `.gguf` file via ADB, the app's startup sequence will instantly bypass the `MODEL_URL` download phase!)*

---

## 🐛 Notable Architecture Fixes Applied

* **Android R8 Minifier & Google ML Kit:** We injected `-dontwarn com.google.mlkit.vision.text.chinese.**` into `proguard-rules.pro` to prevent the release compiler from crashing when it couldn't find the unused 200MB Asian language models.
* **Android Cleartext Traffic Ban:** We modified `AndroidManifest.xml` to allow `usesCleartextTraffic="true"`, preventing Android 9+ from actively severing the connection to your unencrypted local Python server.
* **Internal Thought Leaks:** AI models often "think out loud" (e.g. `<|channel>thought`). The `llm_service.dart` file utilizes a strict backward-scanning Regex that surgically slices off all hallucinated thoughts, internal tokens, and leaked system prompts, guaranteeing the UI exclusively displays the clean `- Threat Level: DANGER` response.
* **Android Doze Mode (Wakelock):** For users downloading the 3.2GB model over Wi-Fi, we integrated `wakelock_plus` to actively fight the Android OS and keep the CPU and Wi-Fi chip awake during the entire 10-minute download.

---

## 📜 License & Usage

SentiNL is completely free and open-source. We strongly encourage developers, researchers, and hobbyists to clone, modify, and distribute this codebase to help build better scam detection tools for vulnerable populations.

If you choose to deploy or integrate this project (including the trained GGUF adapters or the AMD APU training pipelines) in a **commercial product**, we simply require that you provide **attribution and credit** to the original authors by including the `LICENSE` file and copyright notices in your software.
