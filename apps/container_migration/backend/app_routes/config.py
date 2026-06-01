from fastapi import APIRouter, HTTPException
from models.config_model import RuleConfig
from utils.migration_util import load_config, save_config
from app_routes.migration import reload_config

router = APIRouter()

@router.get("")
def get_config():
    try:
        config = load_config()
        return config
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error loading configuration: {str(e)}")
    
    
@router.post("")
def add_rule(rule_config: RuleConfig):
    try:
        config = load_config()
        config.config.append(rule_config)
        save_config(config)
        reload_config()
        return {"message": "New rule added successfully"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error adding RuleConfig: {str(e)}")

@router.delete("/{index}")
def delete_rule_by_index(index: int):
    try:
        config = load_config()
        if index < 0 or index >= len(config.config):
            raise HTTPException(status_code=404, detail=f"Index '{index}' out of range")
        deleted_rule = config.config.pop(index)
        save_config(config)
        reload_config()
        return {"message": f"Rule at index '{index}' deleted successfully", "deleted_rule": deleted_rule}
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Error deleting rule by index: {str(e)}")