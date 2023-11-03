use crate::cli_args::{Language, Template};
use anyhow::{anyhow, Context, Result};
use include_dir::{include_dir, Dir, DirEntry};
use pathdiff::diff_paths;
use std::{
    fmt::Display,
    fs,
    path::{Path, PathBuf},
};

static TEMPLATES_DIR: Dir<'_> = include_dir!("$CARGO_MANIFEST_DIR/templates");

type TemplateDir<'a> = &'a Dir<'a>;

pub struct TemplateDirs<'a> {
    dir: TemplateDir<'a>,
}

pub struct RelativeDir<'a> {
    dir: TemplateDir<'a>,
    pub parent_path: &'a Path,
}

impl<'a> From<TemplateDir<'a>> for RelativeDir<'a> {
    fn from(dir: TemplateDir<'a>) -> Self {
        Self::new(dir)
    }
}

impl<'a> RelativeDir<'a> {
    pub fn new_relative(dir: TemplateDir<'a>, parent_path: &'a Path) -> Self {
        Self { dir, parent_path }
    }

    pub fn new(dir: TemplateDir<'a>) -> Self {
        Self::new_relative(dir, dir.path())
    }

    pub fn get_dir<S>(&self, path: S) -> Option<Self>
    where
        S: AsRef<Path>,
    {
        self.dir
            .get_dir(self.parent_path.join(path))
            .map(|dir| dir.into())
    }

    pub fn path(&self) -> PathBuf {
        diff_paths(self.dir.path(), self.parent_path).unwrap()
    }

    pub fn entries(&self) -> &'a [DirEntry<'a>] {
        self.dir.entries()
    }

    /// Create directories and extract all files to real filesystem.
    /// Creates parent directories of `path` if they do not already exist.
    /// Fails if some files already exist.
    /// In case of error, partially extracted directory may remain on the filesystem.
    pub fn extract<S: AsRef<Path>>(&self, base_path: S) -> Result<()> {
        let base_path = base_path.as_ref();

        for entry in self.dir.entries() {
            let rel_entry_path = diff_paths(entry.path(), self.parent_path).ok_or_else(|| {
                anyhow!("Unexpected, child entry could not diff with parent path")
            })?;

            let path = base_path.join(rel_entry_path);

            match entry {
                DirEntry::Dir(d) => {
                    fs::create_dir_all(&path)?;
                    Self::new_relative(d, self.parent_path).extract(base_path)?;
                }
                DirEntry::File(f) => {
                    fs::write(path, f.contents())?;
                }
            }
        }

        Ok(())
    }
}

#[derive(strum_macros::Display)]
#[strum(serialize_all = "lowercase")]
enum TemplateType {
    Static,
    Dynamic,
}

impl<'a> TemplateDirs<'a> {
    pub fn new() -> Self {
        Self {
            dir: &TEMPLATES_DIR,
        }
    }

    fn get_template_dir(&self, template_type: TemplateType) -> Result<RelativeDir<'a>> {
        self.dir
            .get_dir(template_type.to_string())
            .map(|d| d.into())
            .ok_or_else(|| anyhow!("Unexpected, {} templates dir does not exist", template_type))
    }

    fn get_codegen_dir(&self, template_type: TemplateType) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_template_dir(template_type)
            .context("Failed getting template dir")?;

        template_dir
            .get_dir("codegen")
            .ok_or_else(|| anyhow!("Unexpected, codegen dir does not exist"))
    }

    pub fn get_codegen_static_dir(&self) -> Result<RelativeDir<'a>> {
        self.get_codegen_dir(TemplateType::Static)
    }

    pub fn get_codegen_dynamic_dir(&self) -> Result<RelativeDir<'a>> {
        self.get_codegen_dir(TemplateType::Dynamic)
    }

    fn get_dynamic_dir<T: Display>(&self, dirname: T) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_template_dir(TemplateType::Dynamic)
            .context("Failed getting template dir")?;

        template_dir.get_dir(&dirname.to_string()).ok_or_else(|| {
            anyhow!(
                "Unexpected, dynamic {} dir does not exist at {:?}",
                dirname,
                template_dir.path()
            )
        })
    }

    fn get_contract_import_dynamic_dir<T: Display>(&self, template: T) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_dynamic_dir("contract_import_templates")
            .context("Failed getting template dir")?;

        template_dir.get_dir(template.to_string()).ok_or_else(|| {
            anyhow!(
                "Unexpected, dynamic {} dir does not exist at {:?}",
                template,
                template_dir.path()
            )
        })
    }

    pub fn get_init_template_dynamic_shared(&self) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_dynamic_dir("init_templates")
            .context("Failed getting template dir")?;

        template_dir.get_dir("shared").ok_or_else(|| {
            anyhow!(
                "Unexpected, dynamic shared dir does not exist at {:?}",
                template_dir.path()
            )
        })
    }

    pub fn get_contract_import_shared_dir(&self) -> Result<RelativeDir<'a>> {
        self.get_contract_import_dynamic_dir("shared")
    }

    pub fn get_contract_import_lang_dir(&self, lang: &Language) -> Result<RelativeDir<'a>> {
        self.get_contract_import_dynamic_dir(lang.to_string().to_lowercase())
    }

    fn get_init_template_static_dirs(&self, template: String) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_template_dir(TemplateType::Static)
            .context("Failed getting template dir")?;

        let template_folder_name = format!("{}_template", template);

        template_dir.get_dir(&template_folder_name).ok_or_else(|| {
            anyhow!(
                "Unexpected, static {} dir does not exist at {:?}",
                template_folder_name,
                template_dir.path()
            )
        })
    }

    fn get_template_static_dir(
        &self,
        template: String,
        subdir_name: String,
    ) -> Result<RelativeDir<'a>> {
        let template_dir = self
            .get_init_template_static_dirs(template)
            .context("Failed getting static template dirs")?;

        template_dir.get_dir(&subdir_name).ok_or_else(|| {
            anyhow!(
                "Unexpected, static dir {:?} does not exist for",
                template_dir.path()
            )
        })
    }

    fn get_template_lang_dir(
        &self,
        template: &Template,
        lang: &Language,
    ) -> Result<RelativeDir<'a>> {
        self.get_template_static_dir(
            template.to_string().to_lowercase(),
            lang.to_string().to_lowercase(),
        )
    }

    fn get_template_shared_dir(&self, template: &Template) -> Result<RelativeDir<'a>> {
        self.get_template_static_dir(template.to_string().to_lowercase(), "shared".to_string())
    }

    fn get_blank_lang_dir(&self, lang: &Language) -> Result<RelativeDir<'a>> {
        self.get_template_static_dir("blank".to_string(), lang.to_string().to_lowercase())
    }

    fn get_blank_shared_dir(&self) -> Result<RelativeDir<'a>> {
        self.get_template_static_dir("blank".to_string(), "shared".to_string())
    }

    pub fn get_and_extract_template(
        &self,
        template: &Template,
        lang: &Language,
        project_root: &PathBuf,
    ) -> Result<()> {
        let lang_files = self.get_template_lang_dir(template, lang).context(format!(
            "Failed getting static files for template {} with language {}",
            template, lang
        ))?;

        let shared_files = self.get_template_shared_dir(template).context(format!(
            "Failed getting shared static files for template {}",
            template
        ))?;

        lang_files.extract(project_root).context(format!(
            "Failed extracting static files for template {} with language {}",
            template, lang
        ))?;

        shared_files.extract(project_root).context(format!(
            "Failed extracting shared static files for template {}",
            template
        ))?;

        Ok(())
    }

    pub fn get_and_extract_blank_template(
        &self,
        lang: &Language,
        project_root: &PathBuf,
    ) -> Result<()> {
        let lang_files = self.get_blank_lang_dir(lang).context(format!(
            "Failed getting static files for blank template with language {}",
            lang
        ))?;

        let shared_files = self
            .get_blank_shared_dir()
            .context("Failed getting shared static files for blank template")?;

        lang_files.extract(project_root).context(format!(
            "Failed extracting static files for blank template with language {}",
            lang
        ))?;

        shared_files
            .extract(project_root)
            .context("Failed extracting shared static files for blank template")?;

        Ok(())
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use strum::IntoEnumIterator;
    use tempdir::TempDir;

    #[test]
    fn codegen_templates_exist() {
        let template_dirs = TemplateDirs::new();
        template_dirs
            .get_codegen_static_dir()
            .expect("codegen static");

        template_dirs
            .get_codegen_dynamic_dir()
            .expect("codegen dynamic");
    }

    #[test]
    fn all_init_templates_exist() {
        let template_dirs = TemplateDirs::new();
        for template in Template::iter() {
            for lang in Language::iter() {
                template_dirs
                    .get_template_lang_dir(&template, &lang)
                    .expect("static lang");
            }
            template_dirs
                .get_template_shared_dir(&template)
                .expect("static templte shared");
        }

        template_dirs
            .get_init_template_dynamic_shared()
            .expect("dynami shared init template");
    }

    #[test]
    fn all_init_templates_extract_succesfully() {
        let template_dirs = TemplateDirs::new();
        let temp_dir =
            TempDir::new("init_extract_lang_test").expect("Failed creating tempdir init template");

        for template in Template::iter() {
            for lang in Language::iter() {
                template_dirs
                    .get_and_extract_template(&template, &lang, &(PathBuf::from(temp_dir.path())))
                    .expect("static lang");
            }
        }
        let temp_dir =
            TempDir::new("init_extract_blank_lang_test").expect("Failed creating tempdir blank");
        for lang in Language::iter() {
            template_dirs
                .get_and_extract_blank_template(&lang, &temp_dir.path().into())
                .expect("static blank");
        }
    }

    #[test]
    fn blank_templates_exist() {
        let template_dirs = TemplateDirs::new();
        template_dirs
            .get_blank_shared_dir()
            .expect("static blank shared dir");

        for lang in Language::iter() {
            template_dirs
                .get_blank_lang_dir(&lang)
                .expect("static blank lang");
        }
    }

    #[test]
    fn contract_import_templates_exist() {
        let template_dirs = TemplateDirs::new();
        template_dirs
            .get_contract_import_shared_dir()
            .expect("contract import shared");

        for lang in Language::iter() {
            template_dirs
                .get_contract_import_lang_dir(&lang)
                .expect("contract import lang");
        }
    }

    #[test]
    #[should_panic]
    fn bad_dynamic_dir() {
        let template_dirs = TemplateDirs::new();
        template_dirs.get_dynamic_dir("bad_dynamic_path").unwrap();
    }

    #[test]
    #[should_panic]
    fn bad_dynamic_contract_dir() {
        let template_dirs = TemplateDirs::new();
        template_dirs
            .get_contract_import_dynamic_dir("bad_dynamic_path")
            .unwrap();
    }

    #[test]
    fn relative_dir() {
        let rel_dir = RelativeDir::new(
            super::TEMPLATES_DIR
                .get_dir("static")
                .expect("getting static"),
        );

        let child = rel_dir.get_dir("codegen").unwrap();

        assert_eq!(child.path(), PathBuf::from(""));
    }
}
