from fastapi import APIRouter, HTTPException
from pathlib import Path
from fastapi.responses import JSONResponse, FileResponse
import os

router = APIRouter()

log_directory = "/home/ubuntu/contMigration_logs"

@router.get("/structure")
async def directory_structure():
    directory_structure = get_directory_structure(log_directory)
    return {"data": directory_structure}

@router.get("/view/{file_path:path}")
async def get_file_content(file_path: str):
    try:
        # Resolve the full path of the requested file
        root_path = Path(log_directory).resolve()
        requested_file = (root_path / file_path).resolve()

        # Ensure the requested file is within the allowed directory
        if not requested_file.is_file() or root_path not in requested_file.parents:
            raise HTTPException(status_code=404, detail="File not found or access denied")

        if requested_file.suffix != ".txt":
            raise HTTPException(status_code=400, detail="Only text files are allowed")

        # Read and return the content of the file
        with requested_file.open("r", encoding="utf-8") as file:
            content = file.read()

        return {"content": content}

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"An error occurred: {e}")

@router.get("/download/{file_path:path}")
async def download_file(file_path: str):
    try:
        # Resolve the full path of the requested file
        root_path = Path(log_directory).resolve()
        requested_file = (root_path / file_path).resolve()

        # Ensure the requested file is within the allowed directory and is a .txt file
        if not requested_file.is_file() or root_path not in requested_file.parents:
            raise HTTPException(status_code=404, detail="File not found or access denied")

        if requested_file.suffix != ".txt":
            raise HTTPException(status_code=400, detail="Only text files are allowed")

        # Return the file for download
        return FileResponse(requested_file, media_type='application/octet-stream', filename=requested_file.name)

    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"An error occurred: {e}")

def get_directory_structure(rootdir):
    """
    Creates a nested dictionary that represents the folder structure of rootdir
    """
    def create_node(name, path, is_file):
        # Get relative path from rootdir
        rel_path = os.path.relpath(path, rootdir)
        node = {
            "label": name,
            "data": rel_path,
            "expandedIcon": "pi pi-folder-open" if not is_file else "pi pi-file",
            "collapsedIcon": "pi pi-folder" if not is_file else "pi pi-file",
        }
        if not is_file:
            node["children"] = []
        return node

    def add_children(node, path):
        items = []
        for item in os.listdir(path):
            item_path = os.path.join(path, item)
            if item == "temp":
                continue
            if os.path.isdir(item_path):
                child_node = create_node(item, item_path, False)
                add_children(child_node, item_path)
                items.append(child_node)
            else:
                items.append(create_node(item, item_path, True))
        # Sort items: directories first, then files, both alphabetically
        node["children"] = sorted(items, key=lambda x: (x.get("children") is None, x["label"].lower()))

    root_node = {"children": []}
    add_children(root_node, rootdir)
    return root_node["children"]
