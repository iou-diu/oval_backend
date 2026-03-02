import django_filters
from apps.cms.models import Catalog, CorporateLead
from apps.cms.forms import CatalogFilterForm, CorporateLeadFilterForm

class CatalogFilter(django_filters.FilterSet):
    title = django_filters.CharFilter(field_name='title', lookup_expr='icontains')
    class Meta:
        model = Catalog
        fields = ['title', 'is_published', 'is_featured']
        form = CatalogFilterForm


class CorporateLeadFilter(django_filters.FilterSet):
    company_name = django_filters.CharFilter(field_name='company_name', lookup_expr='icontains')
    class Meta:
        model = CorporateLead
        fields = ['company_name', 'status']
        form = CorporateLeadFilterForm
