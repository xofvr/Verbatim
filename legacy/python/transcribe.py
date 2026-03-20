import requests
import sys
import os

API_KEY = os.environ.get("GROQ_API_KEY", "")
API_URL = "https://api.groq.com/openai/v1/audio/transcriptions"

FILES = [
    "../../fixtures/audio/Desklodge.mp3",
    "../../fixtures/audio/Desklodge_2.mp3",
]

def transcribe(filepath: str) -> str:
    print(f"Transcribing: {filepath} ...")
    if not API_KEY:
        print("Missing GROQ_API_KEY environment variable")
        sys.exit(1)
    with open(filepath, "rb") as f:
        response = requests.post(
            API_URL,
            headers={"Authorization": f"Bearer {API_KEY}"},
            files={"file": (os.path.basename(filepath), f, "audio/mpeg")},
            data={
                "model": "whisper-large-v3",
                "language": "en",
                "response_format": "verbose_json",
                "temperature": "0",
            },
        )
    if response.status_code != 200:
        print(f"Error {response.status_code}: {response.text}")
        sys.exit(1)
    return response.json()


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    for filename in FILES:
        filepath = os.path.join(script_dir, filename)
        result = transcribe(filepath)

        # Save full text
        text = result.get("text", "")
        out_name = os.path.splitext(os.path.basename(filename))[0] + "_transcript.txt"
        out_path = os.path.join(script_dir, out_name)
        with open(out_path, "w") as f:
            f.write(text)

        # Save segmented version with timestamps
        segments = result.get("segments", [])
        if segments:
            seg_name = os.path.splitext(os.path.basename(filename))[0] + "_transcript_timestamped.txt"
            seg_path = os.path.join(script_dir, seg_name)
            with open(seg_path, "w") as f:
                for seg in segments:
                    start = seg.get("start", 0)
                    end = seg.get("end", 0)
                    text_seg = seg.get("text", "").strip()
                    mins_s, secs_s = divmod(start, 60)
                    mins_e, secs_e = divmod(end, 60)
                    f.write(f"[{int(mins_s):02d}:{secs_s:05.2f} -> {int(mins_e):02d}:{secs_e:05.2f}] {text_seg}\n")

        print(f"  Saved: {out_name}")
        print(f"  Duration: {result.get('duration', 'unknown')}s")
        print()

if __name__ == "__main__":
    main()
