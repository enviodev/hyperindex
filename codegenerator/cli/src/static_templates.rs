use crate::cli_args::{Language, Template};
use anyhow::{anyhow, Context, Result};
use include_dir::{include_dir, Dir};

static STATIC_TEMPLATES_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/templates/static");

pub struct StaticTemplates<'a> {
    dir: &'a Dir<'a>,
}

impl<'a> StaticTemplates<'a> {
    pub fn new() -> Self {
        Self {
            dir: &STATIC_TEMPLATES_DIR,
        }
    }

    fn get_codegen_dir(&self) -> Result<&'a Dir<'a>> {
        self.dir
            .get_dir("codegen")
            .ok_or_else(|| anyhow!("Unexpected, static codegen dir does not exist"))
    }

    fn get_template_dirs(&self, template: String) -> Result<&'a Dir<'a>> {
        let template_folder_name = format!("{}_template", template);

        self.dir.get_dir(&template_folder_name).ok_or_else(|| {
            anyhow!(
                "Unexpected, static {} dir does not exist",
                template_folder_name
            )
        })
    }

    fn get_template_dir(&self, template: String, subdir_name: String) -> Result<&'a Dir<'a>> {
        let template_dir = self
            .get_template_dirs(template)
            .context("Failed getting static template dirs")?;

        let path = template_dir.path().join(&subdir_name);

        template_dir
            .get_dir(&path)
            .ok_or_else(|| anyhow!("Unexpected, static dir {:?} does not exist for", path,))
    }

    fn get_template_lang_dir(&self, template: &Template, lang: &Language) -> Result<&'a Dir<'a>> {
        self.get_template_dir(
            template.to_string().to_lowercase(),
            lang.to_string().to_lowercase(),
        )
    }

    fn get_template_shared_dir(&self, template: &Template) -> Result<&'a Dir<'a>> {
        self.get_template_dir(template.to_string().to_lowercase(), "shared".to_string())
    }

    fn get_blank_lang_dir(&self, lang: &Language) -> Result<&'a Dir<'a>> {
        self.get_template_dir("blank".to_string(), lang.to_string().to_lowercase())
    }

    fn get_blank_shared_dir(&self) -> Result<&'a Dir<'a>> {
        self.get_template_dir("blank".to_string(), "shared".to_string())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use strum::IntoEnumIterator;

    #[test]
    fn codegen_dir_exists() {
        StaticTemplates::new().get_codegen_dir().unwrap();
    }

    #[test]
    fn all_templates_exist() {
        let static_templates = StaticTemplates::new();
        for template in Template::iter() {
            for lang in Language::iter() {
                static_templates
                    .get_template_lang_dir(&template, &lang)
                    .expect("failed lang dir does not exist");
            }
            static_templates
                .get_template_shared_dir(&template)
                .expect("failed shared dir does not exist");
        }
        for lang in Language::iter() {
            static_templates
                .get_blank_lang_dir(&lang)
                .expect("failed blank lang dir does not exist");
        }
        static_templates
            .get_blank_shared_dir()
            .expect("failed blank shared dir does not exist");
    }
}
