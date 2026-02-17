import json
import os
from pathlib import Path
from models.config_model import Config

# Get the directory of this script and build path to config.json
current_dir = Path(__file__).parent.parent
config_path = current_dir / "config.json"

def load_config() -> Config:
    with open(config_path, 'r') as config_file:
        config_data = json.load(config_file)
        return Config.model_validate(config_data)
    
def save_config(config: Config):
    with open(config_path, 'w') as config_file:
        json.dump(config.model_dump(), config_file, indent=4)