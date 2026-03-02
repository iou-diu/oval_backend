import django_tables2 as tables
from apps.helpers import CustomTable
from apps.cms.models import Catalog

class CatalogTable(CustomTable):
    edit_url = 'catalog_update'
    delete_url = 'catalog_delete'
    detail_url = 'catalog_detail'  # This will be the "View Page" for products

    class Meta:
        model = Catalog
        template_name = 'django_tables2/bootstrap4.html'
        fields = ['counter', 'title', 'tagline', 'slug', 'is_published', 'is_featured', 'published_date', 'action']
        empty_text = 'No catalogs available'
        orderable = True
        exclude = ('selected',)
