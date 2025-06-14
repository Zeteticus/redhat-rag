#!/usr/bin/env python3
"""
Red Hat Documentation RAG Backend
FastAPI-based backend for intelligent document search and retrieval
Optimized for RHEL 9 with Python 3.12 and Podman
"""

import os
import re
import json
import time
import logging
import hashlib
from datetime import datetime, timedelta
from pathlib import Path
from typing import List, Optional, Dict, Any
from dataclasses import dataclass, asdict
from contextlib import asynccontextmanager

import uvicorn
import PyPDF2
import numpy as np
from fastapi import FastAPI, HTTPException, UploadFile, File, BackgroundTasks
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from sentence_transformers import SentenceTransformer
from sklearn.metrics.pairwise import cosine_similarity
import chromadb
from chromadb.config import Settings

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
class Config:
    DOCUMENTS_DIR = os.getenv('DOCUMENTS_DIR', './documents')
    CHROMA_DB_PATH = os.getenv('CHROMA_DB_PATH', './chromadb')
    MODEL_NAME = os.getenv('EMBEDDING_MODEL', 'all-MiniLM-L6-v2')
    CHUNK_SIZE = int(os.getenv('CHUNK_SIZE', '500'))
    CHUNK_OVERLAP = int(os.getenv('CHUNK_OVERLAP', '50'))
    MAX_RESULTS = int(os.getenv('MAX_RESULTS', '20'))
    MIN_CONFIDENCE = float(os.getenv('MIN_CONFIDENCE', '0.3'))
    
    # Red Hat specific patterns
    RHEL_VERSION_PATTERN = r'(?:RHEL|Red Hat Enterprise Linux)\s*(\d+(?:\.\d+)?)'
    CATEGORY_KEYWORDS = {
        'installation': ['install', 'setup', 'deployment', 'bootstrap'],
        'networking': ['network', 'ip', 'dns', 'dhcp', 'firewall', 'iptables'],
        'security': ['security', 'selinux', 'authentication', 'ssl', 'tls', 'encryption'],
        'storage': ['storage', 'filesystem', 'disk', 'lvm', 'raid', 'mount'],
        'virtualization': ['kvm', 'qemu', 'libvirt', 'virtual', 'hypervisor'],
        'containers': ['container', 'podman', 'docker', 'kubernetes', 'openshift'],
        'troubleshooting': ['troubleshoot', 'debug', 'error', 'problem', 'issue']
    }

# Pydantic Models
class SearchRequest(BaseModel):
    query: str = Field(..., min_length=1, max_length=500)
    filters: Optional[Dict[str, Any]] = Field(default_factory=dict)
    max_results: Optional[int] = Field(default=10, ge=1, le=50)
    min_confidence: Optional[float] = Field(default=0.3, ge=0.0, le=1.0)

class SearchResult(BaseModel):
    id: str
    title: str
    content: str
    source: str
    confidence: float
    category: str
    version: str
    tags: List[str]
    page: int
    section: str
    metadata: Dict[str, Any]

class SearchResponse(BaseModel):
    results: List[SearchResult]
    total_count: int
    response_time_ms: int
    query: str
    filters_applied: Dict[str, Any]

class StatsResponse(BaseModel):
    total_documents: int
    total_chunks: int
    total_queries: int
    avg_response_time_ms: float
    system_status: str
    last_updated: str
    categories: Dict[str, int]
    versions: Dict[str, int]

@dataclass
class DocumentChunk:
    """Represents a chunk of text from a document"""
    id: str
    content: str
    source: str
    page: int
    section: str
    title: str
    category: str
    version: str
    tags: List[str]
    metadata: Dict[str, Any]
    embedding: Optional[np.ndarray] = None

class DocumentProcessor:
    """Handles PDF processing and text extraction"""
    
    def __init__(self):
        self.config = Config()
        
    def extract_text_from_pdf(self, pdf_path: Path) -> List[Dict[str, Any]]:
        """Extract text from PDF with page and section information"""
        try:
            with open(pdf_path, 'rb') as file:
                pdf_reader = PyPDF2.PdfReader(file)
                pages = []
                
                for page_num, page in enumerate(pdf_reader.pages, 1):
                    text = page.extract_text()
                    if text.strip():
                        pages.append({
                            'page': page_num,
                            'text': text,
                            'source': pdf_path.name
                        })
                        
                logger.info(f"Extracted {len(pages)} pages from {pdf_path.name}")
                return pages
                
        except Exception as e:
            logger.error(f"Error processing PDF {pdf_path}: {str(e)}")
            return []
    
    def detect_rhel_version(self, text: str) -> str:
        """Detect RHEL version from document text"""
        match = re.search(self.config.RHEL_VERSION_PATTERN, text, re.IGNORECASE)
        if match:
            version = match.group(1)
            major_version = version.split('.')[0]
            return f"rhel{major_version}"
        return "unknown"
    
    def categorize_content(self, text: str) -> str:
        """Categorize content based on keywords"""
        text_lower = text.lower()
        scores = {}
        
        for category, keywords in self.config.CATEGORY_KEYWORDS.items():
            score = sum(1 for keyword in keywords if keyword in text_lower)
            if score > 0:
                scores[category] = score
                
        return max(scores, key=scores.get) if scores else "general"
    
    def extract_tags(self, text: str) -> List[str]:
        """Extract relevant tags from text"""
        tags = set()
        text_lower = text.lower()
        
        # Technical terms
        tech_patterns = [
            r'\b(systemctl|systemd|firewalld|selinux|podman|docker)\b',
            r'\b(yum|dnf|rpm|subscription-manager)\b',
            r'\b(ssh|http|https|ftp|nfs|samba)\b',
            r'\b(tcp|udp|ip|dns|dhcp)\b'
        ]
        
        for pattern in tech_patterns:
            matches = re.findall(pattern, text_lower)
            tags.update(matches)
            
        return list(tags)[:10]  # Limit to 10 tags
    
    def extract_section_title(self, text: str) -> str:
        """Extract section title from text"""
        lines = text.split('\n')
        for line in lines[:5]:  # Check first 5 lines
            line = line.strip()
            if line and (line.isupper() or line.startswith('Chapter') or 
                        line.startswith('Section') or len(line.split()) <= 8):
                return line[:100]  # Limit length
        return "Content"
    
    def chunk_text(self, text: str, chunk_size: int = None, overlap: int = None) -> List[str]:
        """Split text into overlapping chunks"""
        chunk_size = chunk_size or self.config.CHUNK_SIZE
        overlap = overlap or self.config.CHUNK_OVERLAP
        
        words = text.split()
        chunks = []
        
        for i in range(0, len(words), chunk_size - overlap):
            chunk = ' '.join(words[i:i + chunk_size])
            if chunk.strip():
                chunks.append(chunk)
                
        return chunks
    
    def process_document(self, pdf_path: Path) -> List[DocumentChunk]:
        """Process a PDF document into chunks"""
        pages = self.extract_text_from_pdf(pdf_path)
        if not pages:
            return []
            
        chunks = []
        doc_title = pdf_path.stem.replace('-', ' ').title()
        
        # Detect document-level metadata
        full_text = ' '.join([page['text'] for page in pages])
        doc_version = self.detect_rhel_version(full_text)
        doc_category = self.categorize_content(full_text)
        
        for page_data in pages:
            page_text = page_data['text']
            page_chunks = self.chunk_text(page_text)
            
            for i, chunk_text in enumerate(page_chunks):
                chunk_id = hashlib.md5(
                    f"{pdf_path.name}_{page_data['page']}_{i}".encode()
                ).hexdigest()
                
                chunk = DocumentChunk(
                    id=chunk_id,
                    content=chunk_text,
                    source=pdf_path.name,
                    page=page_data['page'],
                    section=self.extract_section_title(chunk_text),
                    title=doc_title,
                    category=self.categorize_content(chunk_text) or doc_category,
                    version=self.detect_rhel_version(chunk_text) or doc_version,
                    tags=self.extract_tags(chunk_text),
                    metadata={
                        'file_size': pdf_path.stat().st_size,
                        'processed_at': datetime.now().isoformat(),
                        'chunk_index': i,
                        'total_chunks': len(page_chunks)
                    }
                )
                chunks.append(chunk)
                
        logger.info(f"Processed {pdf_path.name}: {len(chunks)} chunks created")
        return chunks

class VectorStore:
    """ChromaDB-based vector storage and retrieval"""
    
    def __init__(self):
        self.config = Config()
        self.client = None
        self.collection = None
        self.model = None
        self._stats = {
            'total_queries': 0,
            'response_times': [],
            'last_updated': datetime.now()
        }
    
    async def initialize(self):
        """Initialize the vector store"""
        try:
            # Initialize ChromaDB
            os.makedirs(self.config.CHROMA_DB_PATH, exist_ok=True)
            self.client = chromadb.PersistentClient(
                path=self.config.CHROMA_DB_PATH,
                settings=Settings(anonymized_telemetry=False)
            )
            
            # Get or create collection
            self.collection = self.client.get_or_create_collection(
                name="redhat_docs",
                metadata={"description": "Red Hat documentation chunks"}
            )
            
            # Initialize embedding model
            logger.info(f"Loading embedding model: {self.config.MODEL_NAME}")
            self.model = SentenceTransformer(self.config.MODEL_NAME)
            
            logger.info("Vector store initialized successfully")
            
        except Exception as e:
            logger.error(f"Failed to initialize vector store: {str(e)}")
            raise
    
    def add_chunks(self, chunks: List[DocumentChunk]):
        """Add document chunks to the vector store"""
        if not chunks:
            return
            
        try:
            # Generate embeddings
            texts = [chunk.content for chunk in chunks]
            embeddings = self.model.encode(texts, show_progress_bar=True)
            
            # Prepare data for ChromaDB
            ids = [chunk.id for chunk in chunks]
            metadatas = []
            documents = []
            
            for chunk in chunks:
                metadatas.append({
                    'source': chunk.source,
                    'page': chunk.page,
                    'section': chunk.section,
                    'title': chunk.title,
                    'category': chunk.category,
                    'version': chunk.version,
                    'tags': json.dumps(chunk.tags),
                    **chunk.metadata
                })
                documents.append(chunk.content)
            
            # Add to collection
            self.collection.add(
                ids=ids,
                embeddings=embeddings.tolist(),
                metadatas=metadatas,
                documents=documents
            )
            
            logger.info(f"Added {len(chunks)} chunks to vector store")
            
        except Exception as e:
            logger.error(f"Error adding chunks to vector store: {str(e)}")
            raise
    
    def search(self, query: str, filters: Dict[str, Any] = None, 
               max_results: int = 10, min_confidence: float = 0.3) -> List[SearchResult]:
        """Search for relevant documents"""
        start_time = time.time()
        
        try:
            # Generate query embedding
            query_embedding = self.model.encode([query])
            
            # Prepare ChromaDB filters
            where_filters = {}
            if filters:
                if filters.get('category'):
                    where_filters['category'] = filters['category']
                if filters.get('version'):
                    where_filters['version'] = filters['version']
            
            # Search in ChromaDB
            results = self.collection.query(
                query_embeddings=query_embedding.tolist(),
                n_results=min(max_results * 2, 100),  # Get more results for filtering
                where=where_filters if where_filters else None
            )
            
            # Process results
            search_results = []
            for i in range(len(results['ids'][0])):
                distance = results['distances'][0][i]
                confidence = 1 - distance  # Convert distance to confidence
                
                if confidence >= min_confidence:
                    metadata = results['metadatas'][0][i]
                    
                    search_result = SearchResult(
                        id=results['ids'][0][i],
                        title=metadata['title'],
                        content=results['documents'][0][i],
                        source=metadata['source'],
                        confidence=round(confidence, 3),
                        category=metadata['category'],
                        version=metadata['version'],
                        tags=json.loads(metadata.get('tags', '[]')),
                        page=metadata['page'],
                        section=metadata['section'],
                        metadata={
                            k: v for k, v in metadata.items() 
                            if k not in ['title', 'source', 'category', 'version', 'tags', 'page', 'section']
                        }
                    )
                    search_results.append(search_result)
            
            # Sort by confidence and limit results
            search_results.sort(key=lambda x: x.confidence, reverse=True)
            search_results = search_results[:max_results]
            
            # Update stats
            response_time = int((time.time() - start_time) * 1000)
            self._stats['total_queries'] += 1
            self._stats['response_times'].append(response_time)
            if len(self._stats['response_times']) > 100:
                self._stats['response_times'] = self._stats['response_times'][-100:]
            
            logger.info(f"Search completed: {len(search_results)} results in {response_time}ms")
            return search_results
            
        except Exception as e:
            logger.error(f"Search error: {str(e)}")
            raise HTTPException(status_code=500, detail=f"Search failed: {str(e)}")
    
    def get_stats(self) -> Dict[str, Any]:
        """Get vector store statistics"""
        try:
            collection_count = self.collection.count()
            
            # Get category and version distributions
            all_results = self.collection.get(include=['metadatas'])
            categories = {}
            versions = {}
            
            for metadata in all_results['metadatas']:
                cat = metadata.get('category', 'unknown')
                ver = metadata.get('version', 'unknown')
                categories[cat] = categories.get(cat, 0) + 1
                versions[ver] = versions.get(ver, 0) + 1
            
            avg_response_time = (
                sum(self._stats['response_times']) / len(self._stats['response_times'])
                if self._stats['response_times'] else 0
            )
            
            return {
                'total_chunks': collection_count,
                'total_queries': self._stats['total_queries'],
                'avg_response_time_ms': round(avg_response_time, 2),
                'categories': categories,
                'versions': versions,
                'last_updated': self._stats['last_updated'].isoformat()
            }
            
        except Exception as e:
            logger.error(f"Error getting stats: {str(e)}")
            return {}

class DocumentManager:
    """Manages document processing and indexing"""
    
    def __init__(self, vector_store: VectorStore):
        self.config = Config()
        self.processor = DocumentProcessor()
        self.vector_store = vector_store
        self.processed_files = set()
        
        # Ensure documents directory exists
        os.makedirs(self.config.DOCUMENTS_DIR, exist_ok=True)
    
    async def scan_and_process_documents(self):
        """Scan documents directory and process new PDFs"""
        docs_path = Path(self.config.DOCUMENTS_DIR)
        pdf_files = list(docs_path.glob("*.pdf"))
        
        logger.info(f"Found {len(pdf_files)} PDF files")
        
        for pdf_path in pdf_files:
            if pdf_path.name not in self.processed_files:
                await self.process_document(pdf_path)
                self.processed_files.add(pdf_path.name)
    
    async def process_document(self, pdf_path: Path):
        """Process a single document"""
        try:
            logger.info(f"Processing document: {pdf_path.name}")
            chunks = self.processor.process_document(pdf_path)
            
            if chunks:
                self.vector_store.add_chunks(chunks)
                logger.info(f"Successfully processed {pdf_path.name}")
            else:
                logger.warning(f"No content extracted from {pdf_path.name}")
                
        except Exception as e:
            logger.error(f"Error processing {pdf_path.name}: {str(e)}")
    
    async def add_document(self, file_content: bytes, filename: str):
        """Add a new document from uploaded content"""
        try:
            pdf_path = Path(self.config.DOCUMENTS_DIR) / filename
            
            with open(pdf_path, 'wb') as f:
                f.write(file_content)
            
            await self.process_document(pdf_path)
            self.processed_files.add(filename)
            
            return {"message": f"Document {filename} processed successfully"}
            
        except Exception as e:
            logger.error(f"Error adding document {filename}: {str(e)}")
            raise HTTPException(status_code=500, detail=f"Failed to process document: {str(e)}")

# Global instances
vector_store = VectorStore()
doc_manager = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan management"""
    # Startup
    logger.info("Starting Red Hat Documentation RAG Backend")
    await vector_store.initialize()
    
    global doc_manager
    doc_manager = DocumentManager(vector_store)
    
    # Process existing documents
    await doc_manager.scan_and_process_documents()
    
    logger.info("Backend initialization complete")
    yield
    
    # Shutdown
    logger.info("Shutting down backend")

# FastAPI application
app = FastAPI(
    title="Red Hat Documentation RAG API",
    description="Intelligent search and retrieval for Red Hat system administration documentation",
    version="1.0.0",
    lifespan=lifespan
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Configure appropriately for production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve static files (frontend)
if os.path.exists("static"):
    app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/")
async def serve_frontend():
    """Serve the frontend HTML"""
    static_path = Path("static/index.html")
    if static_path.exists():
        return FileResponse("static/index.html")
    else:
        return JSONResponse(
            content={"message": "Red Hat Documentation RAG API", "docs": "/docs"},
            status_code=200
        )

@app.post("/api/search", response_model=SearchResponse)
async def search_documents(request: SearchRequest):
    """Search through documentation"""
    start_time = time.time()
    
    try:
        results = vector_store.search(
            query=request.query,
            filters=request.filters,
            max_results=request.max_results,
            min_confidence=request.min_confidence
        )
        
        response_time = int((time.time() - start_time) * 1000)
        
        return SearchResponse(
            results=results,
            total_count=len(results),
            response_time_ms=response_time,
            query=request.query,
            filters_applied=request.filters
        )
        
    except Exception as e:
        logger.error(f"Search API error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/stats", response_model=StatsResponse)
async def get_stats():
    """Get system statistics"""
    try:
        stats = vector_store.get_stats()
        
        # Count total documents
        docs_path = Path(Config.DOCUMENTS_DIR)
        total_docs = len(list(docs_path.glob("*.pdf")))
        
        return StatsResponse(
            total_documents=total_docs,
            total_chunks=stats.get('total_chunks', 0),
            total_queries=stats.get('total_queries', 0),
            avg_response_time_ms=stats.get('avg_response_time_ms', 0),
            system_status="healthy",
            last_updated=stats.get('last_updated', datetime.now().isoformat()),
            categories=stats.get('categories', {}),
            versions=stats.get('versions', {})
        )
        
    except Exception as e:
        logger.error(f"Stats API error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/documents/upload")
async def upload_document(
    background_tasks: BackgroundTasks,
    file: UploadFile = File(...)
):
    """Upload a new PDF document"""
    if not file.filename.lower().endswith('.pdf'):
        raise HTTPException(status_code=400, detail="Only PDF files are supported")
    
    try:
        content = await file.read()
        result = await doc_manager.add_document(content, file.filename)
        
        return JSONResponse(
            content=result,
            status_code=201
        )
        
    except Exception as e:
        logger.error(f"Upload error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/api/documents/{filename}")
async def get_document(filename: str):
    """Retrieve a document file"""
    file_path = Path(Config.DOCUMENTS_DIR) / filename
    
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Document not found")
    
    return FileResponse(
        path=file_path,
        media_type='application/pdf',
        filename=filename
    )

@app.get("/api/documents")
async def list_documents():
    """List all available documents"""
    try:
        docs_path = Path(Config.DOCUMENTS_DIR)
        pdf_files = list(docs_path.glob("*.pdf"))
        
        documents = []
        for pdf_path in pdf_files:
            stat = pdf_path.stat()
            documents.append({
                'filename': pdf_path.name,
                'size': stat.st_size,
                'modified': datetime.fromtimestamp(stat.st_mtime).isoformat(),
                'processed': pdf_path.name in doc_manager.processed_files
            })
        
        return {"documents": documents}
        
    except Exception as e:
        logger.error(f"List documents error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/api/documents/reprocess")
async def reprocess_documents():
    """Reprocess all documents"""
    try:
        doc_manager.processed_files.clear()
        await doc_manager.scan_and_process_documents()
        
        return {"message": "Document reprocessing initiated"}
        
    except Exception as e:
        logger.error(f"Reprocess error: {str(e)}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat(),
        "version": "1.0.0"
    }

if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8080,
        reload=False,
        log_level="info"
    )
