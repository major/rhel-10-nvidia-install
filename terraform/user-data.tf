data "cloudinit_config" "this" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-init.yaml"
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/templates/cloud-init.yaml.tftpl",
      {
        hostname         = var.name_prefix
        auto_reboot      = var.auto_reboot
        install_playbook = file("${path.module}/../ansible/install.yml")
        verify_playbook  = file("${path.module}/../ansible/verify.yml")
        vector_add_src   = file("${path.module}/../ansible/files/vector_add.cu")
        verify_service   = file("${path.module}/../ansible/files/nvidia-verify.service")
      }
    )
  }
}
