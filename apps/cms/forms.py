from django import forms
from apps.cms.models import HomeSlider

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
