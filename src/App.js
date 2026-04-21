import { useState } from "react";
import {
  S3Client,
  ListObjectsV2Command,
  PutObjectCommand,
  DeleteObjectCommand,
  GetObjectCommand,
} from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { XhrHttpHandler } from "@aws-sdk/xhr-http-handler";

const s3 = new S3Client({
  region: "us-east-1",
  requestHandler: new XhrHttpHandler(),
});

const BUCKET_NAME = "marchs3fetu";  ///// Bucket name here

const styles = `
  @import url('https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Syne:wght@400;600;800&display=swap');

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: #0a0a0a;
    color: #f0f0f0;
    font-family: 'Syne', sans-serif;
    min-height: 100vh;
  }

  .app {
    max-width: 780px;
    margin: 0 auto;
    padding: 60px 24px;
  }

  .header {
    margin-bottom: 56px;
  }

  .header-eyebrow {
    font-family: 'Space Mono', monospace;
    font-size: 11px;
    letter-spacing: 0.25em;
    color: #ff6b35;
    text-transform: uppercase;
    margin-bottom: 12px;
  }

  .header h1 {
    font-size: 52px;
    font-weight: 800;
    line-height: 1;
    background: linear-gradient(135deg, #f0f0f0 0%, #666 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    background-clip: text;
  }

  .header-sub {
    font-family: 'Space Mono', monospace;
    font-size: 12px;
    color: #444;
    margin-top: 10px;
    letter-spacing: 0.05em;
  }

  .card {
    background: #111;
    border: 1px solid #1e1e1e;
    border-radius: 16px;
    padding: 32px;
    margin-bottom: 24px;
    transition: border-color 0.2s;
  }

  .card:hover { border-color: #2a2a2a; }

  .card-title {
    font-size: 11px;
    font-weight: 600;
    letter-spacing: 0.2em;
    text-transform: uppercase;
    color: #555;
    font-family: 'Space Mono', monospace;
    margin-bottom: 20px;
  }

  .upload-zone {
    border: 1.5px dashed #2a2a2a;
    border-radius: 12px;
    padding: 28px;
    text-align: center;
    transition: all 0.2s;
    cursor: pointer;
    position: relative;
    margin-bottom: 16px;
  }

  .upload-zone:hover { border-color: #ff6b35; background: #ff6b3506; }

  .upload-zone input {
    position: absolute;
    inset: 0;
    opacity: 0;
    cursor: pointer;
    width: 100%;
  }

  .upload-icon {
    font-size: 28px;
    margin-bottom: 8px;
  }

  .upload-zone-text {
    font-size: 13px;
    color: #555;
    font-family: 'Space Mono', monospace;
  }

  .upload-zone-file {
    font-size: 13px;
    color: #ff6b35;
    font-family: 'Space Mono', monospace;
    font-weight: 700;
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    padding: 12px 24px;
    border-radius: 8px;
    font-family: 'Space Mono', monospace;
    font-size: 12px;
    font-weight: 700;
    letter-spacing: 0.05em;
    cursor: pointer;
    border: none;
    transition: all 0.15s;
  }

  .btn-primary {
    background: #ff6b35;
    color: #0a0a0a;
    width: 100%;
    justify-content: center;
  }

  .btn-primary:hover { background: #ff8555; transform: translateY(-1px); }
  .btn-primary:active { transform: translateY(0); }

  .btn-secondary {
    background: #1a1a1a;
    color: #f0f0f0;
    border: 1px solid #2a2a2a;
  }

  .btn-secondary:hover { background: #222; border-color: #444; }

  .btn-danger {
    background: transparent;
    color: #ff4444;
    border: 1px solid #2a0000;
    padding: 6px 12px;
    font-size: 11px;
  }

  .btn-danger:hover { background: #ff444415; border-color: #ff4444; }

  .file-list { margin-top: 20px; }

  .file-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 0;
    border-bottom: 1px solid #161616;
    gap: 12px;
    transition: opacity 0.2s;
  }

  .file-item:last-child { border-bottom: none; }
  .file-item:hover { opacity: 0.85; }

  .file-info { display: flex; align-items: center; gap: 12px; flex: 1; min-width: 0; }

  .file-icon {
    width: 36px;
    height: 36px;
    background: #1a1a1a;
    border: 1px solid #222;
    border-radius: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 16px;
    flex-shrink: 0;
  }

  .file-name {
    font-size: 14px;
    font-weight: 600;
    color: #e0e0e0;
    cursor: pointer;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    transition: color 0.15s;
  }

  .file-name:hover { color: #ff6b35; }

  .file-size {
    font-family: 'Space Mono', monospace;
    font-size: 11px;
    color: #444;
    flex-shrink: 0;
  }

  .empty-state {
    text-align: center;
    padding: 40px 0;
    font-family: 'Space Mono', monospace;
    font-size: 12px;
    color: #333;
  }

  .status-bar {
    margin-top: 24px;
    padding: 14px 18px;
    background: #111;
    border: 1px solid #1e1e1e;
    border-radius: 10px;
    font-family: 'Space Mono', monospace;
    font-size: 12px;
    color: #888;
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .list-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 4px;
  }
`;

function getFileIcon(name) {
  const ext = name.split(".").pop().toLowerCase();
  if (["jpg", "jpeg", "png", "gif", "webp", "svg"].includes(ext)) return "🖼️";
  if (["pdf"].includes(ext)) return "📄";
  if (["mp4", "mov", "avi"].includes(ext)) return "🎬";
  if (["mp3", "wav", "aac"].includes(ext)) return "🎵";
  if (["zip", "tar", "gz"].includes(ext)) return "📦";
  if (["js", "ts", "jsx", "tsx", "py", "java"].includes(ext)) return "💻";
  return "📁";
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}

export default function App() {
  const [files, setFiles] = useState([]);
  const [uploadFile, setUploadFile] = useState(null);
  const [status, setStatus] = useState("");
  const [loaded, setLoaded] = useState(false);

  const listFiles = async () => {
    setStatus("⟳ Fetching files...");
    try {
      const command = new ListObjectsV2Command({ Bucket: BUCKET_NAME });
      const response = await s3.send(command);
      const items = response.Contents || [];
      setFiles(items);
      setLoaded(true);
      setStatus(`✦ ${items.length} file${items.length !== 1 ? "s" : ""} in bucket`);
    } catch (err) {
      console.error(err);
      setStatus("✕ Error: " + err.message);
    }
  };

  const handleUpload = async () => {
    if (!uploadFile) return setStatus("✕ Select a file first.");
    setStatus("⟳ Uploading...");
    try {
      const arrayBuffer = await uploadFile.arrayBuffer();
      const uint8Array = new Uint8Array(arrayBuffer);
      await s3.send(new PutObjectCommand({
        Bucket: BUCKET_NAME,
        Key: uploadFile.name,
        Body: uint8Array,
        ContentType: uploadFile.type,
      }));
      setStatus(`✦ "${uploadFile.name}" uploaded`);
      setUploadFile(null);
      listFiles();
    } catch (err) {
      console.error(err);
      setStatus("✕ Upload error: " + err.message);
    }
  };

  const handleDelete = async (key) => {
    if (!window.confirm(`Delete "${key}"?`)) return;
    setStatus(`⟳ Deleting "${key}"...`);
    try {
      await s3.send(new DeleteObjectCommand({ Bucket: BUCKET_NAME, Key: key }));
      setStatus(`✦ "${key}" deleted`);
      listFiles();
    } catch (err) {
      console.error(err);
      setStatus("✕ Delete error: " + err.message);
    }
  };

  const handleView = async (key) => {
    setStatus(`⟳ Generating link...`);
    try {
      const url = await getSignedUrl(s3, new GetObjectCommand({
        Bucket: BUCKET_NAME,
        Key: key,
      }), { expiresIn: 60 });
      window.open(url, "_blank");
      setStatus(`✦ Opened "${key}" — link expires in 60s`);
    } catch (err) {
      console.error(err);
      setStatus("✕ Error: " + err.message);
    }
  };

  return (
    <>
      <style>{styles}</style>
      <div className="app">

        {/* Header */}
        <div className="header">
          <div className="header-eyebrow">AWS SDK · S3</div>
          <h1>S3 Explorer</h1>
          <div className="header-sub">bucket: {BUCKET_NAME} · region: us-east-1</div>
        </div>

        {/* Upload Card */}
        <div className="card">
          <div className="card-title">Upload File</div>
          <div className="upload-zone">
            <input
              type="file"
              onChange={(e) => setUploadFile(e.target.files[0])}
            />
            <div className="upload-icon">↑</div>
            {uploadFile
              ? <div className="upload-zone-file">{uploadFile.name}</div>
              : <div className="upload-zone-text">drop file or click to browse</div>
            }
          </div>
          <button className="btn btn-primary" onClick={handleUpload}>
            Upload to S3
          </button>
        </div>

        {/* Files Card */}
        <div className="card">
          <div className="list-header">
            <div className="card-title" style={{ marginBottom: 0 }}>Bucket Files</div>
            <button className="btn btn-secondary" onClick={listFiles}>
              ↻ Refresh
            </button>
          </div>

          <div className="file-list">
            {!loaded && (
              <div className="empty-state">
                hit refresh to load files
              </div>
            )}
            {loaded && files.length === 0 && (
              <div className="empty-state">no files in bucket</div>
            )}
            {files.map((file) => (
              <div className="file-item" key={file.Key}>
                <div className="file-info">
                  <div className="file-icon">{getFileIcon(file.Key)}</div>
                  <span className="file-name" onClick={() => handleView(file.Key)}>
                    {file.Key}
                  </span>
                </div>
                <span className="file-size">{formatSize(file.Size)}</span>
                <button className="btn btn-danger" onClick={() => handleDelete(file.Key)}>
                  delete
                </button>
              </div>
            ))}
          </div>
        </div>

        {/* Status Bar */}
        {status && (
          <div className="status-bar">
            {status}
          </div>
        )}

      </div>
    </>
  );
}