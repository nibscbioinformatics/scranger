FROM nfcore/base:1.9
LABEL authors="Francesco Lescai" \
      description="Docker image containing all software requirements for the nibscbioinformatics/scranger pipeline"

# Install the conda environment
COPY environment.yml /
RUN conda env create -f /environment.yml && conda clean -a

# Add conda installation dir to PATH (instead of doing 'conda activate')
ENV PATH /opt/conda/envs/nibscbioinformatics-scranger-1.0dev/bin:$PATH

# Specific installation of Cellranger 3.1.0
RUN wget -O cellranger-3.1.0.tar.gz "https://nfpipelines.blob.core.windows.net/nftools/cellranger-3.1.0.tar.gz"
RUN tar -xzvf cellranger-3.1.0.tar.gz
ENV PATH /cellranger-3.1.0:$PATH

# Dump the details of the installed packages to a file for posterity
RUN conda env export --name nibscbioinformatics-scranger-1.0dev > nibscbioinformatics-scranger-1.0dev.yml
