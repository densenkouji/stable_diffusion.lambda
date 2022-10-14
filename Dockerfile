FROM public.ecr.aws/ubuntu/ubuntu:20.04 as builder
ARG hf_username
ARG hf_token
WORKDIR /var/task/
RUN apt-get update && apt-get install -y python3-pip curl build-essential gcc make git git-lfs && git lfs install --skip-repo
RUN git clone https://${hf_username}:${hf_token}@huggingface.co/CompVis/stable-diffusion-v1-4
RUN git clone https://github.com/huggingface/diffusers.git -b v0.4.2 --depth 1 
WORKDIR /var/task/diffusers/
RUN curl https://sh.rustup.rs -sSf | sh -s -- -y
RUN pip install torch onnx transformers==4.23.0 onnxruntime ftfy
RUN python3 ./setup.py install
RUN python3 ./scripts/convert_stable_diffusion_checkpoint_to_onnx.py --model_path="../stable-diffusion-v1-4" --output_path="../stable_diffusion_onnx"

FROM public.ecr.aws/lambda/python:3.9 as buildlibGL
RUN yum -y update && yum -y install gcc make gcc-c++ zlib-devel bison bison-devel gzip glibc-static wget tar
RUN wget https://ftp.gnu.org/gnu/glibc/glibc-2.27.tar.gz && tar zxvf glibc-2.27.tar.gz && rm glibc-2.27.tar.gz && mv ./glibc-2.27/ /opt/glibc-2.27/
WORKDIR /opt/glibc-2.27/build
RUN /opt/glibc-2.27/configure --prefix=/var/task && make && make install

FROM public.ecr.aws/lambda/python:3.9 as production
COPY requirements.txt  ./
RUN python -m pip install --upgrade pip && pip install -r requirements.txt && pip cache purge
RUN yum -y update && yum -y install mesa-libGL && yum clean all
COPY --from=builder /var/task/stable_diffusion_onnx /var/runtime/model/
COPY --from=buildlibGL /var/task/lib/libm.so.6 /lib64/

COPY app.py ./
CMD [ "app.handler" ]