import { useState } from "react";

const API = "http://100.31.77.117:4000";

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

  .header { margin-bottom: 56px; }

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

  .upload-icon { font-size: 28px; margin-bottom: 8px; }

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

  .desc-input {
    width: 100%;
    background: #0a0a0a;
    border: 1px solid #2a2a2a;
    border-radius: 8px;
    padding: 12px 16px;
    color: #f0f0f0;
    font-family: 'Space Mono', monospace;
    font-size: 12px;
    margin-bottom: 16px;
    outline: none;
    transition: border-color 0.2s;
  }

  .desc-input:focus { border-color: #ff6b35; }
  .desc-input::placeholder { color: #333; }

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
    padding: 16px 0;
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

  .file-details { min-width: 0; }

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

  .file-desc {
    font-size: 11px;
    color: #444;
    font-family: 'Space Mono', monospace;
    margin-top: 3px;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .file-meta {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 4px;
    flex-shrink: 0;
  }

  .file-size {
    font-family: 'Space Mono', monospace;
    font-size: 11px;
    color: #444;
  }

  .file-date {
    font-family: 'Space Mono', monospace;
    font-size: 10px;
    color: #333;
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
  }

  .list-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 4px;
  }

  .stats-row {
    display: flex;
    gap: 24px;
    margin-bottom: 24px;
  }

  .stat-box {
    flex: 1;
    background: #0a0a0a;
    border: 1px solid #1e1e1e;
    border-radius: 12px;
    padding: 16px;
    text-align: center;
  }

  .stat-number {
    font-size: 28px;
    font-weight: 800;
    color: #ff6b35;
    font-family: 'Syne', sans-serif;
  }

  .stat-label {
    font-size: 10px;
    color: #444;
    font-family: 'Space Mono', monospace;
    text-transform: uppercase;
    letter-spacing: 0.1em;
    margin-top: 4px;
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

function formatDate(dateStr) {
  return new Date(dateStr).toLocaleDateString("en-US", {
    month: "short", day: "numeric", year: "numeric"
  });
}

export default function App() {
  const [files, setFiles] = useState([]);
  const [uploadFile, setUploadFile] = useState(null);
  const [description, setDescription] = useState("");
  const [status, setStatus] = useState("");
  const [loaded, setLoaded] = useState(false);

  const listFiles = async () => {
    setStatus("⟳ Fetching files...");
    try {
      const res = await fetch(`${API}/api/files`);
      const data = await res.json();
      setFiles(data);
      setLoaded(true);
      setStatus(`✦ ${data.length} file${data.length !== 1 ? "s" : ""} in vault`);
    } catch (err) {
      setStatus("✕ Error: " + err.message);
    }
  };

  const handleUpload = async () => {
    if (!uploadFile) return setStatus("✕ Select a file first.");
    setStatus("⟳ Uploading...");
    try {
      const formData = new FormData();
      formData.append("file", uploadFile);
      formData.append("description", description);

      const res = await fetch(`${API}/api/upload`, {
        method: "POST",
        body: formData,
      });
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      setStatus(`✦ "${uploadFile.name}" uploaded`);
      setUploadFile(null);
      setDescription("");
      listFiles();
    } catch (err) {
      setStatus("✕ Upload error: " + err.message);
    }
  };

  const handleDelete = async (id, name) => {
    if (!window.confirm(`Delete "${name}"?`)) return;
    setStatus(`⟳ Deleting "${name}"...`);
    try {
      const res = await fetch(`${API}/api/files/${id}`, { method: "DELETE" });
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      setStatus(`✦ "${name}" deleted`);
      listFiles();
    } catch (err) {
      setStatus("✕ Delete error: " + err.message);
    }
  };

  const handleView = async (id, name) => {
    setStatus(`⟳ Generating link...`);
    try {
      const res = await fetch(`${API}/api/files/${id}/view`);
      const data = await res.json();
      if (data.error) throw new Error(data.error);
      window.open(data.url, "_blank");
      setStatus(`✦ Opened "${name}" — link expires in 60s`);
    } catch (err) {
      setStatus("✕ Error: " + err.message);
    }
  };

  const totalSize = files.reduce((acc, f) => acc + Number(f.file_size), 0);

  return (
    <>
      <style>{styles}</style>
      <div className="app">

        <div className="header">
          <div className="header-eyebrow">AWS S3 + RDS MySQL</div>
          <h1>CloudVault</h1>
          <div className="header-sub">secure cloud file storage — powered by AWS</div>
        </div>

        {/* Stats */}
        {loaded && (
          <div className="stats-row">
            <div className="stat-box">
              <div className="stat-number">{files.length}</div>
              <div className="stat-label">Total Files</div>
            </div>
            <div className="stat-box">
              <div className="stat-number">{formatSize(totalSize)}</div>
              <div className="stat-label">Total Size</div>
            </div>
            <div className="stat-box">
              <div className="stat-number">{files.filter(f => f.description).length}</div>
              <div className="stat-label">Described</div>
            </div>
          </div>
        )}

        {/* Upload Card */}
        <div className="card">
          <div className="card-title">Upload File</div>
          <div className="upload-zone">
            <input type="file" onChange={(e) => setUploadFile(e.target.files[0])} />
            <div className="upload-icon">↑</div>
            {uploadFile
              ? <div className="upload-zone-file">{uploadFile.name}</div>
              : <div className="upload-zone-text">drop file or click to browse</div>
            }
          </div>
          <input
            className="desc-input"
            placeholder="add a description (optional)"
            value={description}
            onChange={(e) => setDescription(e.target.value)}
          />
          <button className="btn btn-primary" onClick={handleUpload}>
            Upload to CloudVault
          </button>
        </div>

        {/* Files Card */}
        <div className="card">
          <div className="list-header">
            <div className="card-title" style={{ marginBottom: 0 }}>Vault Files</div>
            <button className="btn btn-secondary" onClick={listFiles}>↻ Refresh</button>
          </div>

          <div className="file-list">
            {!loaded && <div className="empty-state">hit refresh to load files</div>}
            {loaded && files.length === 0 && <div className="empty-state">no files in vault</div>}
            {files.map((file) => (
              <div className="file-item" key={file.id}>
                <div className="file-info">
                  <div className="file-icon">{getFileIcon(file.file_name)}</div>
                  <div className="file-details">
                    <div className="file-name" onClick={() => handleView(file.id, file.file_name)}>
                      {file.file_name}
                    </div>
                    {file.description && (
                      <div className="file-desc">{file.description}</div>
                    )}
                  </div>
                </div>
                <div className="file-meta">
                  <span className="file-size">{formatSize(file.file_size)}</span>
                  <span className="file-date">{formatDate(file.uploaded_at)}</span>
                </div>
                <button className="btn btn-danger" onClick={() => handleDelete(file.id, file.file_name)}>
                  delete
                </button>
              </div>
            ))}
          </div>
        </div>

        {status && <div className="status-bar">{status}</div>}
      </div>
    </>
  );
}