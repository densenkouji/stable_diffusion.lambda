# -- coding: utf-8 --`
import os
import gc
from datetime import datetime
import numpy as np
from diffusers import StableDiffusionOnnxPipeline
import boto3

s3_client = boto3.client('s3')
s3_resource = boto3.resource('s3')

# S3 Bucket Name
BUCKET_NAME = os.environ['BUCKET']

DEFAULT_SEED = None # random seed for generating consistent images per prompt
DEFAULT_NUM_INFERENCE_STEPS = 32  # num inference steps
DEFAULT_GUIDANCE_SCALE = 7.5  # guidance scale
DEFAULT_PROMPT = "Street-art painting of Sakura with tower in style of Banksy"  # prompt
DEFAULT_NEGATIVE_PROMPT = ""
DEFAULT_OUTPUT = "output"  # output image name
# TODO:
# DEFAULT_INIT_IMAGE = None  # path to initial image
# DEFAULT_STRENGTH = 0.5 # how strong the initial image should be noised [0.0, 1.0]
# DEFAULT_MASK = None  # mask of the region to inpaint on the initial image

pipeOnnx = StableDiffusionOnnxPipeline.from_pretrained(
        "/var/runtime/model/",
        provider="CPUExecutionProvider"
        )

def file_exists_s3(filename):
    try:
        result = s3_client.list_objects(Bucket=BUCKET_NAME, Prefix=filename )["Contents"]
        if len(result) > 0:
           return True
        else:
           return False
    except:
        return False

def download_file_s3(file_from, save_to):
    if file_exists_s3(file_from):
        try:
            s3_resource.Bucket(BUCKET_NAME).download_file(file_from, '/tmp/' + save_to)
            return True
        except:
            return False
    else:
        return False

def get_latents_from_seed(seed: int, width: int, height:int) -> np.ndarray:
    # 1 is batch size
    latents_shape = (1, 4, height // 8, width // 8)
    # Gotta use numpy instead of torch, because torch's randn() doesn't support DML
    rng = np.random.default_rng(seed)
    image_latents = rng.standard_normal(latents_shape).astype(np.float32)
    return image_latents

def handler(event, context):
    global pipeOnnx
    seed = event.setdefault('seed', DEFAULT_SEED)
    if seed is None:
        import random
        seed = random.randint(0,4294967295)
    np.random.seed(seed)

    latents=get_latents_from_seed(seed, 512, 512)

    prompt = event.setdefault('prompt', DEFAULT_PROMPT)
    negative_prompt = event.setdefault('negative_prompt', DEFAULT_NEGATIVE_PROMPT)
    steps = event.setdefault('num_inference_steps', DEFAULT_NUM_INFERENCE_STEPS)
    guidance_scale = event.setdefault('guidance_scale', DEFAULT_GUIDANCE_SCALE)

    image = pipeOnnx(prompt, negative_prompt=negative_prompt, width=512, height=512, num_inference_steps=steps, guidance_scale=guidance_scale, latents=latents, tensor_format="np").images[0]
    output_img = event.setdefault('output', 'sd') + '_' + str(seed) + '_' + datetime.now().strftime('%Y-%m-%d-%H-%M-%S') + '.png'
    image.save('/tmp/' + output_img)
    del latents, image

    bucket = s3_resource.Bucket(BUCKET_NAME)
    bucket.upload_file('/tmp/' + output_img, output_img)
    gc.collect()

    return  {"statusCode": 200, "body": {"bucket":BUCKET_NAME, "output": output_img, "seed":seed, "prompt": event.setdefault('prompt', DEFAULT_PROMPT) }}
