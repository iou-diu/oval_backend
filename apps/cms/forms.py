from django import forms
from crispy_forms.helper import FormHelper
from crispy_forms.layout import Layout, Row, Column, Submit, HTML
from apps.cms.models import HomeSlider, Catalog

class HomeSliderForm(forms.ModelForm):
    class Meta:
        model = HomeSlider
        fields = ['type', 'title', 'description', 'image', 'button_title', 'button_link', 'order']
        widgets = {
            'type': forms.TextInput(attrs={'class': 'form-control'}),
            'title': forms.TextInput(attrs={'class': 'form-control'}),
            'description': forms.TextInput(attrs={'class': 'form-control'}),
            'image': forms.ClearableFileInput(attrs={'class': 'form-control'}),
            'button_title': forms.TextInput(attrs={'class': 'form-control'}),
            'button_link': forms.Textarea(attrs={'class': 'form-control', 'rows': 2}),
            'order': forms.NumberInput(attrs={'class': 'form-control'}),
        }

class CatalogForm(forms.ModelForm):
    class Meta:
        model = Catalog
        fields = [
            'tagline', 'title', 'slug', 'description', 
            'banner_image', 'thumbnail_image', 
            'is_published', 'is_featured', 
            'published_date', 'meta_description'
        ]
        widgets = {
            'tagline': forms.TextInput(attrs={'class': 'form-control'}),
            'title': forms.TextInput(attrs={'class': 'form-control'}),
            'slug': forms.TextInput(attrs={'class': 'form-control'}),
            'description': forms.Textarea(attrs={'class': 'form-control', 'rows': 3}),
            'banner_image': forms.ClearableFileInput(attrs={'class': 'form-control'}),
            'thumbnail_image': forms.ClearableFileInput(attrs={'class': 'form-control'}),
            'is_published': forms.CheckboxInput(attrs={'class': 'form-check-input'}),
            'is_featured': forms.CheckboxInput(attrs={'class': 'form-check-input'}),
            'published_date': forms.DateInput(attrs={'class': 'form-control', 'type': 'date'}),
            'meta_description': forms.Textarea(attrs={'class': 'form-control', 'rows': 3}),
        }

class CatalogFilterForm(forms.Form):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.helper = FormHelper()
        self.helper.form_method = 'get'
        self.helper.layout = Layout(
            Row(
                Column('title', css_class='form-group col-md-4 mb-0'),
                Column('is_published', css_class='form-group col-md-2 mb-0'),
                Column('is_featured', css_class='form-group col-md-2 mb-0'),
                Column(HTML("""<button class='btn btn-lg btn-primary'>Filter</button>"""),
                       css_class='form-group col-md-2 p-5 mb-0'),
            ),
        )
