import os
import sys
import json
import random
import logging
import torch
from datasets import load_dataset
from transformers import AutoTokenizer, AutoModelForCausalLM
from transformers.utils import logging as hf_logging
from peft import LoraConfig, get_peft_model
from trl import SFTTrainer, SFTConfig
from tqdm import tqdm

USE_LOCAL_MODEL = True
LOCAL_MODEL_PATH = "./local-gemma-model"
HF_MODEL_NAME = "google/gemma-4-E2b-it"
DATASET_PATH = "scam_dataset.jsonl"
OUTPUT_DIR = "gemma-scam-toolbox-output"
MAX_SEQ_LENGTH = 2048

print("🚀 Starting SentiNL All-in-One Fine-Tuning Pipeline...")

if not torch.cuda.is_available():
    print("⚠️ WARNING: PyTorch cannot see your GPU! You may have created the toolbox without the --device flags.")

def format_conversation(text, label, explanation):
    return {
        "messages": [
            {"role": "system", "content": "You are a Scam Detection Assistant. Analyze the text for threats and return an assessment."},
            {"role": "user", "content": text},
            {"role": "assistant", "content": explanation}
        ]
    }

print("--- STEP 1: DOWNLOADING & PREPARING DATASET ---")
conversations = []

try:
    print("Loading ucirvine/sms_spam...")
    sms_dataset = load_dataset("ucirvine/sms_spam", split="train")
    for item in tqdm(sms_dataset, desc="Processing UCI SMS Spam"):
        label = item['label']
        text = item['sms']
        if label == 1:
            explanation = "Danger: This message is classified as spam or a smishing attempt. It exhibits patterns common in unsolicited malicious messages."
        else:
            explanation = "Safe: This appears to be a normal, benign text message."
        conversations.append(format_conversation(text, label, explanation))
except Exception as e:
    print(f"Error loading sms_spam: {e}")

try:
    print("Loading notd5a/malicious-benign-sms-mms-dataset...")
    sms2_dataset = load_dataset("notd5a/malicious-benign-sms-mms-dataset", data_files="dataset_v3_for_deberta.csv", split="train")
    indices = random.sample(range(len(sms2_dataset)), min(5000, len(sms2_dataset)))
    sampled_sms2 = sms2_dataset.select(indices)
    for item in tqdm(sampled_sms2, desc="Processing Smishing Dataset"):
        text = str(item.get('TEXT', item.get('text', '')))
        label = item.get('LABEL', item.get('label', 0))
        if label == 1:
            explanation = "Danger: This message contains strong indicators of smishing or malicious intent."
        else:
            explanation = "Safe: This appears to be a normal, benign text message."
        conversations.append(format_conversation(text, label, explanation))
except Exception as e:
    print(f"Error loading smishing dataset: {e}")

try:
    print("Loading zefang-liu/phishing-email-dataset...")
    email_dataset = load_dataset("zefang-liu/phishing-email-dataset", split="train")
    indices = random.sample(range(len(email_dataset)), min(5000, len(email_dataset)))
    sampled_emails = email_dataset.select(indices)
    for item in tqdm(sampled_emails, desc="Processing Phishing Emails"):
        text = str(item.get('Email Text', ''))
        label_str = str(item.get('Email Type', ''))
        if 'Phishing' in label_str:
            explanation = "Danger: This email exhibits deceptive patterns consistent with phishing scams."
            conversations.append(format_conversation(text, 1, explanation))
        elif 'Safe' in label_str:
            explanation = "Safe: This appears to be a normal, benign email."
            conversations.append(format_conversation(text, 0, explanation))
except Exception as e:
    print(f"Error loading phishing emails: {e}")

try:
    print("Loading kmack/Phishing_urls...")
    phishing_dataset = load_dataset("kmack/Phishing_urls", split="train")
    phishing_only = phishing_dataset.filter(lambda x: x['label'] == 1)
    indices = random.sample(range(len(phishing_only)), min(5000, len(phishing_only)))
    sampled_urls = phishing_only.select(indices)
    for item in tqdm(sampled_urls, desc="Processing Phishing URLs"):
        text = item['text']
        explanation = "Danger: This URL exhibits deceptive patterns consistent with phishing scams."
        conversations.append(format_conversation(text, 1, explanation))
except Exception as e:
    print(f"Error loading phishing_urls: {e}")

random.shuffle(conversations)

print(f"Writing {len(conversations)} rows to {DATASET_PATH}...")
with open(DATASET_PATH, 'w', encoding='utf-8') as f:
    for conv in tqdm(conversations, desc="Saving to disk"):
        f.write(json.dumps(conv) + '\n')

print("\n--- STEP 2: LOADING MODEL & TOKENIZER ---")

model_id = LOCAL_MODEL_PATH if USE_LOCAL_MODEL else HF_MODEL_NAME
print(f"Loading model from: {model_id} (Local Mode: {USE_LOCAL_MODEL})")

os.environ["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', stream=sys.stdout)
hf_logging.set_verbosity_info()

tokenizer = AutoTokenizer.from_pretrained(model_id, local_files_only=USE_LOCAL_MODEL)

model = AutoModelForCausalLM.from_pretrained(
    model_id,
    torch_dtype=torch.bfloat16,
    device_map="auto",
    attn_implementation="eager",
    local_files_only=USE_LOCAL_MODEL,
)

print("\n--- STEP 3: APPLYING LORA ADAPTERS ---")
lora_config = LoraConfig(
    r=16,
    lora_alpha=16,
    target_modules=[
        "q_proj.linear",
        "k_proj.linear",
        "v_proj.linear",
        "o_proj.linear",
        "gate_proj.linear",
        "up_proj.linear",
        "down_proj.linear",
    ],
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)

model = get_peft_model(model, lora_config)
model.print_trainable_parameters()

print("\n--- STEP 4: FORMATTING DATASET ---")
dataset = load_dataset("json", data_files={"train": DATASET_PATH}, split="train")

def formatting_prompts_func(examples):
    convos = examples["messages"]
    texts = [
        tokenizer.apply_chat_template(
            convo, tokenize=False, add_generation_prompt=False
        )
        for convo in convos
    ]
    return {"text": texts}

dataset = dataset.map(formatting_prompts_func, batched=True)

print("\n--- STEP 5: CONFIGURING TRAINER & STARTING ---")
training_args = SFTConfig(
    output_dir=OUTPUT_DIR,
    dataset_text_field="text",
    max_length=MAX_SEQ_LENGTH,
    per_device_train_batch_size=4,
    gradient_accumulation_steps=4,
    warmup_steps=10,
    num_train_epochs=3,
    learning_rate=2e-4,
    bf16=True,
    logging_steps=5,
    optim="adamw_torch",
    save_strategy="epoch",
    report_to="none",
    disable_tqdm=False,
)

trainer = SFTTrainer(
    model=model,
    train_dataset=dataset,
    processing_class=tokenizer,
    args=training_args,
)

trainer.train()

print("\n--- STEP 6: SAVING ADAPTER ---")
trainer.model.save_pretrained(f"{OUTPUT_DIR}/adapter")
tokenizer.save_pretrained(f"{OUTPUT_DIR}/adapter")
print(f"✅ Training complete! Adapter saved to {OUTPUT_DIR}/adapter")

print("\n--- STEP 7: MERGING LORA INTO BASE MODEL ---")
import gc
from peft import PeftModel

del model
del trainer
torch.cuda.empty_cache()
gc.collect()

print("Loading base model into CPU for safe merging...")
base_model = AutoModelForCausalLM.from_pretrained(
    model_id,
    torch_dtype=torch.bfloat16,
    device_map="cpu",
    local_files_only=USE_LOCAL_MODEL,
)
print("Merging adapter into base model...")
model_to_merge = PeftModel.from_pretrained(base_model, f"{OUTPUT_DIR}/adapter")
merged_model = model_to_merge.merge_and_unload()

print("Saving merged model to disk...")
merged_model.save_pretrained(f"{OUTPUT_DIR}/merged")
tokenizer.save_pretrained(f"{OUTPUT_DIR}/merged")
print("✅ Merged model saved!")

print("\n--- STEP 8: EXPORTING TO GGUF VIA LLAMA.CPP ---")
import subprocess

print("Cloning and compiling llama.cpp... (This will take a moment)")
subprocess.run("git clone https://github.com/ggerganov/llama.cpp.git || true", shell=True)
subprocess.run("cd llama.cpp && cmake -B build && cmake --build build --config Release -j 16", shell=True)
subprocess.run("pip install -r llama.cpp/requirements.txt --break-system-packages", shell=True)

print("Converting merged model to F16 GGUF...")
subprocess.run(f"python3 llama.cpp/convert_hf_to_gguf.py {OUTPUT_DIR}/merged --outfile {OUTPUT_DIR}/gemma-4-E2b-scam-f16.gguf --outtype f16", shell=True)

print("Quantizing to Q4_K_M...")
subprocess.run(f"./llama.cpp/build/bin/llama-quantize {OUTPUT_DIR}/gemma-4-E2b-scam-f16.gguf {OUTPUT_DIR}/gemma-4-E2b-scam-q4_k_m.gguf q4_k_m", shell=True)

print(f"\n✅ FULL PIPELINE COMPLETE! Model is located at: {OUTPUT_DIR}/gemma-4-E2b-scam-q4_k_m.gguf")
