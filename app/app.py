from flask import Flask, jsonify
import os
app = Flask(__name__)
ROLE = os.getenv("ROLE","unknown").upper()
REGION = os.getenv("REGION","unknown")
@app.get("/")
def index(): return f"<h1>{ROLE} REGION</h1><p>Region: {REGION}</p>"
@app.get("/health")
def health(): return jsonify({"status":"ok","role":ROLE,"region":REGION})
